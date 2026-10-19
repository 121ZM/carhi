/**
 * 长时任务保活（后台持续推流的前提）
 *
 * 为什么需要：用户把系统驾驶模式/导航切到前台后，本应用会退到后台，
 * 系统默认会冻结它 —— 推流会断。必须申请"长时任务"才能继续跑。
 *
 * 模式选择（有 SDK 文档依据，不是猜的）：
 *   - BackgroundMode.AUDIO_RECORDING = 3
 *     官方用途描述："recording and screen capture in the background"
 *     —— 这是**唯一**明确覆盖"屏幕采集"的模式，必须申请成功。
 *   - ❌ 不再申请 BackgroundMode.LOCATION = 4（2026-10-16 移除，理由见 acquire() 内注释）：
 *     长时任务的规则是"申请的类型**必须有对应业务在跑**"，否则会被系统**挂起**；
 *     而挂起后切后台必定冻结 —— 比不申请更糟。本应用并无定位业务。
 *   - 对比 BackgroundMode.DATA_TRANSFER = 1
 *     用途是"上传下载"，且文档明确写着超过 10 分钟不更新进度会被系统取消 ——
 *     对持续投屏场景是错的，不采用。
 *
 * ★ 2026-10-16 新增：长时任务生命周期监听（挂起 / 激活 / 取消）。
 *
 *   起因：大哥报告「投屏时切应用掉线」。
 *
 *   关键背景 —— 长时任务**不是"申请到就一劳永逸"**：
 *     系统会校验"申请的类型"与"实际在跑的业务"是否匹配，不匹配就**挂起**任务；
 *     而任务一旦被挂起，官方语义是（见 `continuousTaskSuspend` 文档原文）：
 *       "When a continuous task is suspended, the application will be suspended
 *        when switched to the background and automatically activated when brought
 *        back to the foreground."
 *     即：切后台 → **整个应用被冻结** → 采集与心跳全停 → 车机 5 秒超时断开。
 *
 *   最可疑的一条挂起原因是 `SYSTEM_SUSPEND_AUDIO_RECORDING_NOT_RUNNING = 7`：
 *     "A continuous task of the AUDIO_RECORDING type is requested, but audio
 *      recording is not in progress."
 *
 *   ⇒ 本模块把挂起事件记录下来（静态字段 + hilog）。UI 镜像后，
 *     **切回前台即可看到"刚才是否被挂起、原因是什么"，无需连 hdc 抓日志**。
 *
 * 实现说明：这里刻意使用**枚举重载**逐个申请，而不用 string[] 重载 ——
 * 后者的模式字符串字面量在类型声明中未公开，写错会在编译期报错，
 * 枚举重载是类型安全的。
 *
 * 申请策略：先申请 AUDIO_RECORDING（必需），再尝试追加 LOCATION（加分项）。
 * AUDIO_RECORDING 失败时返回失败原因，由上层决定如何提示用户。
 */

import { common, wantAgent, Want, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** ★ 统一 hilog 口径：domain A00001 / tag CarHi（与其它模块一致）。
 *  用 console.* 的话 tag 不是 CarHi，按 `CarHi` 过滤日志会漏掉这些行。 */
const DOMAIN: number = 0x0001;
const LOG_TAG: string = 'CarHi';

/** 申请结果 */
export interface KeepAliveResult {
  ok: boolean;
  /** 实际生效的模式描述，供 UI 展示 */
  mode: string;
  /** 失败原因（ok=false 时非空） */
  reason: string;
}

export class BackgroundKeeper {
  private static context: common.UIAbilityContext | null = null;
  private static active: boolean = false;
  private static activeMode: string = '';

  // ================= 长时任务生命周期诊断（2026-10-16） =================
  // 说明：这些是**普通静态字段**，UI 必须镜像成 @State 才会刷新。
  /** 生命周期监听是否已注册（幂等用） */
  private static eventsBound: boolean = false;
  /** 被挂起次数 */
  private static suspendCount: number = 0;
  /** 被重新激活次数 */
  private static activeCount: number = 0;
  /** 被取消次数（例如用户划掉常驻通知） */
  private static cancelCount: number = 0;
  /** 最近一次挂起原因（ContinuousTaskSuspendReason；-1 = 无） */
  private static lastSuspendReason: number = -1;
  /** 最近一次挂起的补充说明（API 26 的 SuspendMessage.message） */
  private static lastSuspendMsg: string = '';
  /** 最近一次取消原因（ContinuousTaskCancelReason；-1 = 无） */
  private static lastCancelReason: number = -1;
  /** 是否**真的**处于过挂起态（suspendState == true） */
  private static everSuspended: boolean = false;

  /** 由 EntryAbility 在启动时注入上下文 */
  static init(context: common.UIAbilityContext): void {
    BackgroundKeeper.context = context;
  }

  /** 是否已持有长时任务 */
  static get isActive(): boolean {
    return BackgroundKeeper.active;
  }

  /** 当前生效的模式描述（未持有时为空串） */
  static get mode(): string {
    return BackgroundKeeper.activeMode;
  }

  /** 是否曾发生挂起 —— UI 可直接据此标红 */
  static get wasSuspended(): boolean {
    return BackgroundKeeper.everSuspended;
  }

  /** 挂起 / 激活 / 取消 计数摘要 */
  static get taskEventSummary(): string {
    return `挂起 ${BackgroundKeeper.suspendCount} / 激活 ${BackgroundKeeper.activeCount}`
      + ` / 取消 ${BackgroundKeeper.cancelCount}`;
  }

  /**
   * 诊断一句话（给 UI 直接显示）。
   *
   * 判读：
   *   - 显示「未发生挂起」→ 掉线**不是**长时任务被挂起导致的，往别处查；
   *   - 显示「曾被挂起：★AUDIO_RECORDING 音频录制未进行」→ 根因确认，换模式或真采音频。
   */
  static get diagText(): string {
    if (BackgroundKeeper.cancelCount > 0) {
      return `⚠ 长时任务被取消 ${BackgroundKeeper.cancelCount} 次`
        + `（reason=${BackgroundKeeper.lastCancelReason}）`
        + `｜${BackgroundKeeper.taskEventSummary}`;
    }
    if (BackgroundKeeper.everSuspended) {
      const msg: string = BackgroundKeeper.lastSuspendMsg.length > 0
        ? `｜${BackgroundKeeper.lastSuspendMsg}` : '';
      return `⚠ 曾被挂起：${BackgroundKeeper.suspendReasonName(BackgroundKeeper.lastSuspendReason)}`
        + `${msg}｜${BackgroundKeeper.taskEventSummary}`;
    }
    return `✔ 未发生挂起｜${BackgroundKeeper.taskEventSummary}`;
  }

  /** 挂起原因 → 人话（枚举值取自 backgroundTaskManager.ContinuousTaskSuspendReason） */
  private static suspendReasonName(reason: number): string {
    switch (reason) {
      case backgroundTaskManager.ContinuousTaskSuspendReason.SYSTEM_SUSPEND_DATA_TRANSFER_LOW_SPEED:
        return 'DATA_TRANSFER 传输速率过低';
      case backgroundTaskManager.ContinuousTaskSuspendReason.SYSTEM_SUSPEND_AUDIO_PLAYBACK_NOT_USE_AVSESSION:
        return 'AUDIO_PLAYBACK 未接入 AVSession';
      case backgroundTaskManager.ContinuousTaskSuspendReason.SYSTEM_SUSPEND_AUDIO_PLAYBACK_NOT_RUNNING:
        return 'AUDIO_PLAYBACK 音频播放未进行';
      case backgroundTaskManager.ContinuousTaskSuspendReason.SYSTEM_SUSPEND_AUDIO_RECORDING_NOT_RUNNING:
        return '★AUDIO_RECORDING 音频录制未进行（名实不符）';
      case backgroundTaskManager.ContinuousTaskSuspendReason.SYSTEM_SUSPEND_LOCATION_NOT_USED:
        return 'LOCATION 定位服务未使用';
      case backgroundTaskManager.ContinuousTaskSuspendReason.SYSTEM_SUSPEND_BLUETOOTH_NOT_USED:
        return 'BLUETOOTH 蓝牙未使用';
      case backgroundTaskManager.ContinuousTaskSuspendReason.SYSTEM_SUSPEND_MULTI_DEVICE_NOT_USED:
        return 'MULTI_DEVICE_CONNECTION 多设备连接未使用';
      case backgroundTaskManager.ContinuousTaskSuspendReason.SYSTEM_SUSPEND_USED_ILLEGALLY:
        return '长时任务类型使用非法';
      default:
        return `未知原因(${reason})`;
    }
  }

  /**
   * 注册长时任务生命周期监听（挂起 / 激活 / 取消）。幂等：重复调用只绑定一次。
   *
   * ⚠ 这是判定"切后台掉线"根因的**唯一可靠手段**：
   *   采集看门狗（ArkUI setInterval）在后台会被一起冻结，面板停更 ≠ 断流；
   *   而本事件由系统在**挂起之前**发出，必定先于冻结到达。
   */
  private static bindTaskEvents(): void {
    if (BackgroundKeeper.eventsBound) {
      return;
    }
    BackgroundKeeper.eventsBound = true;

    try {
      backgroundTaskManager.on('continuousTaskSuspend',
        (info: backgroundTaskManager.ContinuousTaskSuspendInfo): void => {
          BackgroundKeeper.suspendCount++;
          if (info.suspendState) {
            BackgroundKeeper.everSuspended = true;
          }
          BackgroundKeeper.lastSuspendReason = info.suspendReason;
          const sm: backgroundTaskManager.SuspendMessage | undefined = info.suspendMessage;
          BackgroundKeeper.lastSuspendMsg = sm !== undefined ? sm.message : '';
          const line: string = `★[保活] 长时任务挂起 id=${info.continuousTaskId}`
            + ` suspendState=${info.suspendState}`
            + ` reason=${info.suspendReason}`
            + `（${BackgroundKeeper.suspendReasonName(info.suspendReason)}）`
            + (BackgroundKeeper.lastSuspendMsg.length > 0
              ? ` msg=${BackgroundKeeper.lastSuspendMsg}` : '');
          hilog.warn(DOMAIN, LOG_TAG, line);
        });
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, LOG_TAG, `[保活] on(continuousTaskSuspend) 失败: ${err.message}`);
    }

    try {
      backgroundTaskManager.on('continuousTaskActive',
        (info: backgroundTaskManager.ContinuousTaskActiveInfo): void => {
          BackgroundKeeper.activeCount++;
          hilog.info(DOMAIN, LOG_TAG,
            `★[保活] 长时任务重新激活 id=${info.id}（累计 ${BackgroundKeeper.activeCount} 次）`);
        });
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, LOG_TAG, `[保活] on(continuousTaskActive) 失败: ${err.message}`);
    }

    try {
      backgroundTaskManager.on('continuousTaskCancel',
        (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
          BackgroundKeeper.cancelCount++;
          BackgroundKeeper.lastCancelReason = info.reason;
          hilog.warn(DOMAIN, LOG_TAG,
            `★[保活] 长时任务被取消 id=${info.id} reason=${info.reason}`
            + `（累计 ${BackgroundKeeper.cancelCount} 次）`);
        });
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, LOG_TAG, `[保活] on(continuousTaskCancel) 失败: ${err.message}`);
    }

    hilog.info(DOMAIN, LOG_TAG, '[保活] 长时任务生命周期监听已注册');
  }

  /** 查询本应用全部长时任务（含已挂起）——确认"真的申请到了"以及"当前是否挂起" */
  private static async dumpTaskState(ctx: common.UIAbilityContext): Promise<void> {
    try {
      const tasks: backgroundTaskManager.ContinuousTaskInfo[] =
        await backgroundTaskManager.getAllContinuousTasks(ctx, true);
      if (tasks.length === 0) {
        hilog.warn(DOMAIN, LOG_TAG, '★[保活] getAllContinuousTasks 为空 —— 长时任务未生效！');
        return;
      }
      for (const t of tasks) {
        hilog.info(DOMAIN, LOG_TAG,
          `★[保活] task id=${t.continuousTaskId} modes=${t.backgroundModes.join('|')}`
          + ` suspended=${t.suspendState} ability=${t.abilityName}`);
      }
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, LOG_TAG, `[保活] getAllContinuousTasks 失败: ${err.message}`);
    }
  }

  /** 构造通知点击后跳回本应用的 WantAgent */
  private static async buildAgent(ctx: common.UIAbilityContext): Promise<WantAgent> {
    const want: Want = {
      bundleName: ctx.abilityInfo.bundleName,
      abilityName: ctx.abilityInfo.name
    };
    const agentInfo: wantAgent.WantAgentInfo = {
      wants: [want],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    return await wantAgent.getWantAgent(agentInfo);
  }

  /**
   * 申请长时任务。幂等：已持有则直接返回成功。
   *
   * 先申请 AUDIO_RECORDING（采屏必需），成功后再尝试追加 LOCATION 作为加成。
   */
  static async acquire(): Promise<KeepAliveResult> {
    const ctx = BackgroundKeeper.context;
    if (ctx === null) {
      hilog.warn(DOMAIN, LOG_TAG, '[保活] context 未就绪，跳过申请');
      return { ok: false, mode: '', reason: 'Ability 上下文未就绪' };
    }

    // ★ 无论是否已持有，都先把生命周期监听挂上（幂等）——
    //   挂起可能发生在任何时刻，越早监听越好。
    BackgroundKeeper.bindTaskEvents();

    if (BackgroundKeeper.active) {
      return { ok: true, mode: BackgroundKeeper.activeMode, reason: '' };
    }

    let agent: WantAgent | null = null;
    try {
      agent = await BackgroundKeeper.buildAgent(ctx);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, LOG_TAG, `[保活] getWantAgent 失败: ${err.message}`);
      return { ok: false, mode: '', reason: `构建通知失败: ${err.message}` };
    }

    // ---- 第 1 步：采屏模式（必需）----
    try {
      await backgroundTaskManager.startBackgroundRunning(
        ctx,
        backgroundTaskManager.BackgroundMode.AUDIO_RECORDING,
        agent
      );
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, LOG_TAG,
        `[保活] AUDIO_RECORDING 申请失败 code=${err.code} msg=${err.message}`);
      // 常见原因：用户关闭了本应用的通知权限
      return {
        ok: false,
        mode: '',
        reason: `长时任务申请失败(${err.code}): ${err.message}`
      };
    }

    BackgroundKeeper.active = true;
    BackgroundKeeper.activeMode = '仅采屏';
    hilog.info(DOMAIN, LOG_TAG, '[保活] AUDIO_RECORDING 长时任务申请成功');

    // ---- 第 2 步：**不再**追加 LOCATION（2026-10-16 移除）----
    //
    // ★ 原实现把 LOCATION 当"抗回收加成"额外申请，这是**错的**。
    //
    //   长时任务的规则不是"申请越多越安全"，而是"**申请的类型必须有对应业务在跑**"：
    //   系统会校验匹配性，不匹配就把该任务**挂起**
    //   （`ContinuousTaskSuspendReason.SYSTEM_SUSPEND_LOCATION_NOT_USED = 8`：
    //    "A continuous task of the LOCATION type is requested, but the location
    //     service is not in use."）。
    //
    //   而**任务被挂起比不申请更糟** —— 官方语义（`continuousTaskSuspend` 文档）：
    //     "the application will be suspended when switched to the background"
    //   挂起后切后台**必定**冻结；"不申请"至少还留有系统自行判断的余地。
    //
    //   核实依据：本应用 ArkTS 侧全仓 grep `geoLocationManager` / `getCurrentLocation` /
    //   `locationChange` / `requestLocation` **零命中** ⇒ 没有定位业务 ⇒ LOCATION 名实不符
    //   ⇒ 是"切应用掉线"的**第二个**隐患，必须去掉。
    //
    //   注：module.json5 里的 ohos.permission.LOCATION 权限保留（将来真做导航可能用），
    //       但**不再申请对应的长时任务**。

    // ---- 第 3 步：回读任务真实状态（含是否已挂起）----
    await BackgroundKeeper.dumpTaskState(ctx);

    return { ok: true, mode: BackgroundKeeper.activeMode, reason: '' };
  }

  /** 释放长时任务（幂等） */
  static async release(): Promise<void> {
    const ctx = BackgroundKeeper.context;
    if (ctx === null || !BackgroundKeeper.active) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(ctx);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, LOG_TAG, `[保活] stopBackgroundRunning 失败: ${err.message}`);
    }
    BackgroundKeeper.active = false;
    BackgroundKeeper.activeMode = '';
  }
}
