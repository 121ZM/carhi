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
 *   - BackgroundMode.LOCATION = 4
 *     用途是持续定位。车载投屏场景下手机通常同时开着导航，
 *     额外持有定位长时任务可以降低被系统回收的概率。
 *     申请失败不影响主功能，只是抗回收的加成。
 *   - 对比 BackgroundMode.DATA_TRANSFER = 1
 *     用途是"上传下载"，且文档明确写着超过 10 分钟不更新进度会被系统取消 ——
 *     对持续投屏场景是错的，不采用。
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

const TAG = 'CarLifeBackground';

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
      console.warn(`${TAG} context not ready, skip`);
      return { ok: false, mode: '', reason: 'Ability 上下文未就绪' };
    }
    if (BackgroundKeeper.active) {
      return { ok: true, mode: BackgroundKeeper.activeMode, reason: '' };
    }

    let agent: WantAgent | null = null;
    try {
      agent = await BackgroundKeeper.buildAgent(ctx);
    } catch (e) {
      const err = e as BusinessError;
      console.error(`${TAG} getWantAgent failed: ${err.message}`);
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
      console.error(`${TAG} AUDIO_RECORDING failed: ${err.message}`);
      // 常见原因：用户关闭了本应用的通知权限
      return {
        ok: false,
        mode: '',
        reason: `长时任务申请失败(${err.code}): ${err.message}`
      };
    }

    BackgroundKeeper.active = true;
    BackgroundKeeper.activeMode = '仅采屏';
    console.info(`${TAG} continuous task acquired (AUDIO_RECORDING)`);

    // ---- 第 2 步：追加定位模式（加分项，失败不影响主功能）----
    try {
      await backgroundTaskManager.startBackgroundRunning(
        ctx,
        backgroundTaskManager.BackgroundMode.LOCATION,
        agent
      );
      BackgroundKeeper.activeMode = '采屏+定位';
      console.info(`${TAG} extra continuous task acquired (LOCATION)`);
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`${TAG} LOCATION mode skipped: ${err.message}`);
    }

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
      console.error(`${TAG} stopBackgroundRunning failed: ${err.message}`);
    }
    BackgroundKeeper.active = false;
    BackgroundKeeper.activeMode = '';
  }
}
