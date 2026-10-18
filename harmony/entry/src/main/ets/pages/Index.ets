/**
 * CarHi 主页面 —— 车机 HMI（路线 A：自绘界面，纯 ArkUI）
 *
 * ## 界面结构（依据 design/nav-hmi/index.html 视觉稿）
 *
 * ```
 * ┌────┬──────────────┬────────────────────┐
 * │ 栏 │  导航转向卡   │                    │
 * │ 112│──────────────│      地图（占满）    │
 * │ 图标│  音频迷你卡   │                    │
 * └────┴──────────────┴────────────────────┘
 * ```
 *
 *   左栏   = 纯图标导航（首页 / 导航 / 设置），112px
 *   中列   = 440px：上导航转向卡 + 下音频迷你卡（常驻，非独立页）
 *   右侧   = 地图铺满，**不承载任何浮层**
 *
 * ## ★ 为什么去掉了 XComponent
 *
 * 旧实现里有一块 `XComponent(SURFACE)`，原意是把画面编码推给车机。
 * 但经 SDK 查证：ArkUI 绘制的内容**不会**进入 XComponent 的 Surface，
 * 二者是两条独立通路（A2 机制不存在）。结果是那块 Surface 一帧不画、
 * 露出纯黑底（2026-10-13 真机截图实测中部区域全为 (0,0,0)）。
 *
 * 当前目标定为「**先只做屏上显示**」，推流链路暂不接 —— 故移除该 XComponent，
 * 界面全部由 ArkUI 正常绘制。
 *
 * ## 诊断面板
 *
 * 诊断内容（状态 / 通道 / Wi-Fi / 日志）已**并入设置页**，不再是悬浮按钮
 * 或独立侧栏 —— 界面上不留多余入口，排查时进设置即可。
 *
 * ── 2026-10-14 视觉稿落地 ──
 * 删除录屏/推流相关 UI，改为纯 ArkUI 的 HMI 布局。
 */

import { CarLifeEngine, EngineListener } from '../core/CarLifeEngine';
import { NativeHmiSource, HMI_PAGE_HOME, HMI_PAGE_NAVI, HMI_TURN_RIGHT,
  HMI_BACKEND_AUTO, HMI_BACKEND_GPU, HMI_BACKEND_CPU, HmiStatePayload,
  HmiDiag, runHmiSelfCheck, HmiSelfCheckOutcome } from '../core/NativeHmiSource';
import { HandshakeState, stateName } from '../core/StateMachine';
import { BackgroundKeeper } from '../core/BackgroundKeeper';
import { ALL_CHANNELS, ChannelDef } from '../protocol/Constants';
import { CarLifeRuntime } from '../entryability/EntryAbility';
import { WifiDirectCard } from './WifiDirectCard';
import { NaviInfoProbe } from '../core/NaviInfoProbe';
import { mapAmapIconToTurnType, turnTypeActionText } from '../core/AmapIconMapper';
import { AmapNaviPage } from './AmapNaviPage';
import { MapPage } from './MapPage';
import { ScreenCaptureSource } from '../core/ScreenCaptureSource';
import { image } from '@kit.ImageKit';
import { display, floatView, window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import carlifecodec from 'libcarlifecodec.so';

/** SectionCard 未传内容时的占位（@BuilderParam 需要默认值） */
@Builder
function EmptyContent() {
}

/**
 * 引擎单例（模块级）。
 *
 * 为什么提到模块级：本应用要在**长时任务下持续后台运行**，
 * 而页面的 ArkUI 实例在切后台/重建时会销毁重建。若把引擎挂在页面实例上，
 * 每次重建都会重新 start() → 与车机的连接被反复重建 → 表现为周期性掉线。
 * 提到模块级后，引擎生命周期独立于页面，页面只负责「订阅状态 + 手动停止」。
 */
export class EngineHolder {
  private static inst: CarLifeEngine | null = null;
  private static listenerRef: EngineListener | null = null;
  /**
   * 全局唯一的画面来源。
   *
   * ★ 2026-10-14 路线 A1 切换：由 CanvasFrameSource（ArkUI 截图）改为
   *   NativeHmiSource（native 自绘）。理由是后台推流是刚需，而 ArkUI 的
   *   渲染权在系统手里 —— 切后台系统停渲染，截图就冻结了。
   *
   * 为什么放这里而不是页面里：页面重建时若重建编码器，车机侧要重新等 I 帧，
   * 表现为画面闪断。单例保证编码器状态跨页面重建存活。
   */
  private static src: NativeHmiSource | null = null;

  static get engine(): CarLifeEngine | null {
    return EngineHolder.inst;
  }

  static get isRunning(): boolean {
    return EngineHolder.inst !== null;
  }

  /** 画面来源（未创建时为 null） */
  static get frameSource(): NativeHmiSource | null {
    return EngineHolder.src;
  }

  /**
   * ★ 强制画面源（应用投屏用）。
   *
   * 非 null 时，引擎取画面源会**优先用它**（= 录屏采集）；
   * 置回 null 即恢复 native 自绘。这是「应用投屏 ⇄ 自绘」的切换开关。
   *
   * 为什么用"覆盖"而不是"替换工厂"：工厂在 `start()` 里注册后，
   * 引擎内部按需 `factory()` 取源；改工厂要拿到引擎私有字段，
   * 而一个静态覆盖位更简单、也更容易在页面重建后保持。
   */
  private static forcedCapture: ScreenCaptureSource | null = null;

  static setForceCaptureSource(src: ScreenCaptureSource | null): void {
    EngineHolder.forcedCapture = src;
  }

  static get forceCaptureSource(): ScreenCaptureSource | null {
    return EngineHolder.forcedCapture;
  }

  /** 懒创建画面来源（单例） */
  static ensureFrameSource(): NativeHmiSource {
    if (EngineHolder.src === null) {
      EngineHolder.src = new NativeHmiSource();
    }
    return EngineHolder.src;
  }

  /** 把当前 HMI 状态推给 native（未运行时静默忽略） */
  static pushHmi(payload: HmiStatePayload): void {
    const src = EngineHolder.src;
    if (src === null || !src.isRunning) {
      return;
    }
    src.setPage(payload.page);
    src.setConnected(payload.connected !== 0);
    src.setNavi(payload.navi.turnType, payload.navi.distanceText, payload.navi.distanceUnit,
      payload.navi.road, payload.navi.hint, payload.navi.nextHint, payload.navi.progress);
    src.setAudio(payload.audio.title, payload.audio.artist,
      payload.audio.positionMs, payload.audio.durationMs, payload.audio.playing !== 0);
  }

  /** 启动（幂等）。若已有引擎则仅切换 UI 回调，不重启底层服务。 */
  static async start(listener: EngineListener): Promise<boolean> {
    EngineHolder.listenerRef = listener;
    if (EngineHolder.inst !== null) {
      return false;   // 未新建，调用方据此判断
    }
    const eng = new CarLifeEngine(listener);
    // ★ 音频通路：把保活采集拿到的内录 PCM 转给引擎发车机（Ch3/9240）。
    //   官方 SDK 的 FEATURE_CONFIG_AUDIO_TRANSMISSION_MODE 默认 0 = 专用音频通道。
    //   采集参数 = NativeHmiSource 里 KeepAliveCapture 的配置（48000Hz/2ch），
    //   位深按 OH_AVScreenCapture 原始流惯例假设 16bit —— 待真机用 buffer 尺寸核实。
    //   startAudioStream 每帧都调但**幂等**（已 INIT 则直接返回），这样
    //   画面源切换/通道重连后第一帧就能自动补 INIT，不依赖外部标志位。
    CarLifeRuntime.audioSink = (pcm: Uint8Array, timestampUs: number, sourceType: number) => {
      if (sourceType !== 1) {
        return;   // 只发内录（系统播放音频）
      }
      eng.startAudioStream(48000, 2, 16);
      eng.sendAudioFrame(pcm, timestampUs);
    };
    // 把画布来源接进引擎：车机确认开始推流时，引擎通过这个工厂拿画面产出者。
    // ★ 若已设置「强制画面源」（应用投屏），就用它 —— 于是车机看到的是手机屏幕。
    eng.setFrameSourceFactory(() => {
      const forced = EngineHolder.forcedCapture;
      if (forced !== null) {
        return forced;
      }
      return EngineHolder.ensureFrameSource();
    });
    await eng.start();
    EngineHolder.inst = eng;
    return true;      // 新建成功
  }

  /** 用户主动停止。 */
  static stop(): void {
    EngineHolder.inst?.stop();
    EngineHolder.inst = null;
    EngineHolder.listenerRef = null;
    // 解除音频 sink：旧引擎已停，别让画面源（可能还在跑）继续往它发
    CarLifeRuntime.audioSink = null;
    // 注意：**不销毁 src**。它持有 surfaceId，页面重建后还要复用。
  }
}

/** 统一的卡片容器 */
@Component
struct SectionCard {
  @Prop title: string = '';
  @BuilderParam content: () => void = EmptyContent;

  build() {
    Column({ space: 8 }) {
      Text(this.title)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor('#8B949E')
        .width('100%')
      this.content()
    }
    .width('100%')
    .padding(10)
    .backgroundColor('#161B22')
    .border({ width: 1, color: '#21262D', radius: 8 })
    .alignItems(HorizontalAlign.Start)
  }
}

@Entry
@Component
struct Index {
  @State running: boolean = false;
  @State stateText: string = '未连接';
  @State logs: string[] = [];
  @State channelConnected: boolean[] = [];
  @State fps: number = 0;
  @State kbps: number = 0;
  @State frameTotal: number = 0;
  @State statusMessage: string = '正在自动启动监听服务...';
  /** 保活状态镜像（BackgroundKeeper.isActive 是静态字段，必须同步进 @State） */
  @State keeperActive: boolean = false;
  /** ★ 长时任务挂起诊断镜像（BackgroundKeeper.diagText 是静态 getter，同样必须同步） */
  @State keeperDiag: string = '';
  /** 「已切后台」镜像 */
  @State backgrounded: boolean = false;
  // ---- 机制验证探针（路线 A 用）----
  /** 是否正在跑验证（跑的时候会阻塞几秒，需禁用按钮） */
  @State probeRunning: boolean = false;
  /** 最近一次验证结果（多行文本，直接显示在诊断面板里） */
  @State probeResult: string = '';

  // ---- 车机 HMI 状态 ----
  /** 控制车机渲染器当前页面：0 首页 / 1 导航。手机端只显示设置，不预览 HMI。 */
  @State page: number = 1;
  /** 音频播放状态（UI 展示用；实际音频走 9240 通道） */
  @State playing: boolean = false;
  @State trackName: string = '未选择曲目';
  @State trackArtist: string = '媒体源待接入';
  @State progressSec: number = 84;      // 已播秒数（占位）
  @State durationSec: number = 238;     // 总秒数（占位）

  // ---- 首页附加卡（参考 carwith_car_hmi_home.html 设计稿）----
  /** 顶部状态栏：时间 / 信号格数 / 运营商 / 电量 */
  @State statusClock: string = '01:18';
  @State statusSignalBars: number = 4;
  @State statusCarrier: string = '5G';
  @State statusBattery: number = 78;
  /** 天气卡 */
  @State weatherTemp: number = 26;
  @State weatherCondition: string = '多云';
  @State weatherCity: string = '上海';
  @State weatherAir: string = '空气优';
  /** 通勤/到达卡 */
  @State etaMinutes: number = 28;
  @State etaArriveAt: string = '09:10';

  // ---- ★ 应用投屏（录屏采集 → 推车机）----
  @State castRunning: boolean = false;
  @State castText: string = '';
  /** 采集源实例（全局唯一，与自绘源互斥） */
  private castSrc: ScreenCaptureSource | null = null;

  // ---- ★ 小窗投屏（只投本应用当前窗口那一块）----
  //
  // 为什么这么做：应用**不能**自建全局悬浮窗（FLOAT_VIEW 等权限要求系统应用，
  // 声明后装机直接失败 9568289，见 EntryAbility.ets 的实测注释）。可行路径是
  // 用户用系统「智慧多窗」把本应用拖成悬浮小窗，然后只把这块矩形推给车机 ——
  // 手机其余部分照常使用其他 App。
  @State regionOnly: boolean = false;
  @State regionText: string = '';
  /**
   * ★★ 当前是否处于**系统悬浮小窗**（`WindowStatusType.FLOATING`）。
   *
   * 这条路径不靠应用自己开窗，而是用户用系统「智慧多窗」把本应用拖成小窗，
   * 由 `windowStatusChange` 事件驱动（见 `startRegionWatch`）。声明
   * `supportWindowMode: [..., "floating"]` 之后系统才允许这么拖。
   *
   * 置 true 时整个界面切成**纯地图 16:9**（`floatMode` 分支），否则车机看到的是设置列表。
   */
  @State floatMode: boolean = false;
  /** 窗口矩形监听（`window.on` 返回 void，这里只记是否已注册） */
  private regionWin: window.Window | null = null;
  private regionWatching: boolean = false;
  /** 独立投屏子窗口（null = 未打开） */
  private castWin: window.Window | null = null;
  /** 系统级悬浮窗控制器（floatView；null = 未使用） */
  private floatCtl: floatView.FloatViewController | null = null;
  /** 投屏窗口是否已打开（★ 必须镜像成 @State 才会驱动 UI 刷新） */
  @State castWinOpen: boolean = false;

  /**
   * ★ 采集存活诊断（2026-10-15 新增）。
   *
   * 目的：让大哥**在车机上直接判读**采集有没有停摆，不必连 USB 抓日志。
   * 判读要点（务必看最后两条，那是唯一能证伪"没停"的指标）：
   *   - frames 累计出帧数：**只增不减**是正常历史，停止增长才可疑
   *   - fps    实测帧率：卡住时归零
   *   - lastOut 距上次出帧的毫秒数：**这个一直涨 = 采集已经断流**（最硬的指标）
   *   - size   编码器实际输出尺寸（硬件对齐后的真值）
   */
  @State castFrames: number = 0;
  @State castFps: number = 0;
  @State castLastOutMs: number = -1;
  @State castSize: string = '';
  @State castWatchdogText: string = '未开启';
  /** 每秒诊断轮询定时器 id（-1 = 无） */
  private castTimerId: number = -1;
  /** 累计出帧数（native 真值，不经过 ArkUI 状态，避免刷新干扰） */
  private castFramesRaw: number = 0;
  /** 最近一次出帧的墙钟毫秒 */
  private castLastFrameAt: number = 0;
  /** 上一次轮询时的帧数（算 fps 用） */
  private castFramesPrev: number = 0;
  /** 上一次轮询时刻 */
  private castTickAt: number = 0;

  // ---- A3′：高德原生导航页（画面由高德渲染）----
  /** 是否显示高德导航页（全屏覆盖在设置页上） */
  @State showAmapNavi: boolean = false;
  /** 是否显示高德 MapView 真地图页 */
  @State showRealMap: boolean = false;
  /** 是否由真地图页发起了当前投屏；退出地图时只停止本页启动的投屏 */
  private realMapStartedCast: boolean = false;
  /** 导航起终点（默认北京西站 → 天安门，便于验证） */
  @State amapStartLat: number = 39.894911;
  @State amapStartLng: number = 116.322220;
  @State amapStartName: string = '北京西站';
  @State amapEndLat: number = 39.908722;
  @State amapEndLng: number = 116.397499;
  @State amapEndName: string = '天安门';
  /** true = 模拟导航（验证用） */
  @State amapEmulator: boolean = true;

  // ---- Car Kit 导航信息探针（路线 A：复用高德导航能力）----
  @State naviProbeText: string = '';
  @State naviProbeBusy: boolean = false;
  /** 导航指引（占位数据，待接地图源） */
  @State navDistance: string = '300';
  @State navUnit: string = 'm';
  @State navRoad: string = '科技路';
  /** 转向类型（由高德 mIcon 映射而来） */
  @State navTurnType: number = 2;
  /** HMI→车机 日志的秒级去重（诊断用） */
  private lastHmiLogSec: number = 0;
  @State navHint: string = '前方路口右转进入科技路';
  @State navNext: string = '然后 直行 1.2 km';
  /** 导航段进度 0-100（CarWith 语义：铺满导航卡背景的进度条） */
  @State navProgress: number = 42;

  // ---- 自绘诊断（设置页展示；native 侧数据是静态的，只能轮询同步）----
  /** 自绘诊断单行文本 */
  @State hmiDiagText: string = '未运行';
  /** 当前后端：0 = GPU OnScreen，1 = CPU 位图，-1 = 未知/兜底 */
  @State hmiBackend: number = -1;
  /**
   * 用户**请求**的后端（0 自动 / 1 GPU / 2 CPU）。
   *
   * 与 hmiBackend（实际生效的）分开：按钮高亮看请求值，文案看实际值。
   * 否则「自动」和「GPU」会在 GPU 生效时同时高亮，语义就混了。
   */
  @State hmiBackendReq: number = HMI_BACKEND_AUTO;
  /** 是否处于「截图推流」兜底模式 */
  @State hmiFallback: boolean = false;
  /** 是否处于自测模式（无车机） */
  @State hmiSelfTest: boolean = false;
  /** 离线自检（渲染器 ≠ 编码器）结果文本；空串 = 还没跑过 */
  @State hmiCheckText: string = '';
  /** 离线自检进行中（防重入：native 侧是同步阻塞的） */
  @State hmiCheckBusy: boolean = false;

  private scroller: Scroller = new Scroller();
  private tickTimer: number = -1;
  /**
   * 兜底模式下的截图推流定时器。
   *
   * 仅在 `frameSource.isFallback` 为真时启动 —— 那是「native 自绘起不来」
   * 时唯一的画面来源（前台可用，切后台会冻结，但总比一片黑强）。
   */
  private fallbackTimer: number = -1;
  private fallbackBusy: boolean = false;
  private fallbackBuf: ArrayBuffer | null = null;
  /** 兜底首帧是否已打过诊断日志（避免每帧刷屏） */
  private fallbackLogged: boolean = false;
  /** 诊断：截图被跳过的原因只打一次 */
  private fallbackMaskLogged: boolean = false;
  /** A3′：引擎截图首帧日志只打一次 */
  private amapFrameLogged: boolean = false;
  /** A3′：引擎截图错误日志只打一次 */
  private amapFrameErrLogged: boolean = false;
  /** A3′：喂帧诊断的秒级去重 */
  private amapFeedLogSec: number = 0;

  aboutToAppear(): void {
    const states: boolean[] = [];
    for (let i = 0; i < ALL_CHANNELS.length; i++) {
      states.push(false);
    }
    this.channelConnected = states;

    // ★★ 2026-10-16 修复：**绝不要把「函数」写进 AppStorage**。
    //
    // 原来这里是：
    //   AppStorage.setOrCreate<() => void>('carhiFloatClickHandler', () => { ... });
    // 用来把悬浮球的点击转发到本页（悬浮球在独立窗口 pages/FloatBall.ets）。
    //
    // 但 ArkUI 的状态管理**不接受函数作为装饰变量值**，启动时 `aboutToAppear`
    // 直接抛错、进程被系统杀掉（release 包真机实测）：
    //   Error code: 140115
    //   Illegal variable value error with decorated variable 'carhiFloatClickHandler':
    //   failed validation: ... but not function ... attempt to assign value type: 'function'
    //   → FRAMEWORK,PROCESS_KILL,JS_ERROR / Kill Reason: Js Error
    //
    // 而悬浮球方案本身**已经作废**（`ohos.permission.FLOAT_VIEW` 是 system_basic，
    // 声明即装机失败 9568289，见 module.json5 注释），`EntryAbility.tryShowFloatBall`
    // 也**从未被调用**（全仓仅剩定义）—— 所以这段注册是**纯死代码**，直接删掉。
    //
    // ⚠️ 将来若要恢复悬浮球：**不要**再用 AppStorage 传函数。
    //    改用 `emitter`（`@ohos.events.emitter`）发事件，或用一个 @State 计数器
    //    当"点击信号"由页面 watch 它。AppStorage 只能放 boolean/number/string/对象。
    AppStorage.setOrCreate<boolean>('carhiFloatOn', this.castRunning);

    // 统一轮询：日志 + 静态状态源（都不是 @State，只能定时同步）。
    // 只在变化时赋值，避免每 300ms 空刷新。
    this.tickTimer = setInterval(() => {
      if (CarLifeRuntime.logs.length !== this.logs.length) {
        this.logs = CarLifeRuntime.logs.slice();
        this.scroller.scrollEdge(Edge.Bottom);
      }
      if (this.keeperActive !== BackgroundKeeper.isActive) {
        this.keeperActive = BackgroundKeeper.isActive;
      }
      // ★ 长时任务挂起诊断同步：应用若被系统挂起，本定时器也会一起冻结；
      //   但挂起**之前**系统已把事件写进 BackgroundKeeper 的静态字段，
      //   所以切回前台后这一行必定能反映出"刚才是否被挂起、原因是什么"。
      {
        const dg: string = BackgroundKeeper.diagText;
        if (this.keeperDiag !== dg) {
          this.keeperDiag = dg;
        }
      }
      if (this.backgrounded !== !CarLifeRuntime.foregrounded) {
        this.backgrounded = !CarLifeRuntime.foregrounded;
      }
      // ★ 车机画面（原生自绘）的状态同步。
      //   放在这个 300ms 轮询里，是因为所有 HMI 字段都是 @State，
      //   没有集中的"变更钩子"；300ms 一次整包推送开销可忽略。
      //   ★ 顺序很重要：先拉高德真实数据覆盖占位值，再整包推给渲染器。
      this.syncFromAmap();
      this.syncHmi();
      // native 侧诊断数据同样是静态的，一起轮询同步（设置页要显示）
      this.syncHmiDiag();
      // 兜底模式（截图推流）下，画面得由这里驱动
      this.ensureFallbackPush();
    }, 300);

    // 进入首页即自动启动监听服务（无需手动点击）。
    // 服务启动后立刻申请长时任务，保证切后台/熄屏时监听与保活不被冻结。
    this.startService().catch((e: Error) => {
      CarLifeRuntime.addLog(`自动启动失败: ${e.message}`);
    });

    // ★★ 窗口监听**无条件注册**（2026-10-18）：
    //   系统「智慧多窗」把本应用拖成悬浮小窗时会触发 `windowStatusChange`，
    //   这里必须一直在听，否则用户拖出小窗后应用毫无反应。
    //   同时兼容旧的手动开关（`regionOnly`）。
    this.startRegionWatch();
  }

  aboutToDisappear(): void {
    // ⚠ 不要在这里 engine.stop()：
    //   本应用的目标是「长时任务下持续后台运行」，而页面消失（切后台）恰是常态。
    //   若在此停服务，每次切后台都会断开与车机的连接、回来重新握手。
    //   引擎的停止由用户点「停止服务」，或 EntryAbility.onDestroy 统一处理。
    if (this.tickTimer !== -1) {
      clearInterval(this.tickTimer);
      this.tickTimer = -1;
    }
    this.stopFallbackPush();
  }

  build() {
    Stack() {
      this.SettingsPage()

      // ★ A3′：高德原生导航页（全屏覆盖）。
      //   打开时高德自己渲染完整导航界面（地图/路线/红绿灯/路口图），
      //   关闭后回到设置页。详见 pages/AmapNaviPage.ets 顶部注释。
      //   ★ 小窗模式下不挂载：地图实例只能有一个，两套同时渲染会互相打架。
      if (!this.floatMode && this.showAmapNavi) {
        Column() {
          AmapNaviPage({
            startLat: this.amapStartLat,
            startLng: this.amapStartLng,
            startName: this.amapStartName,
            endLat: this.amapEndLat,
            endLng: this.amapEndLng,
            endName: this.amapEndName,
            emulator: this.amapEmulator,
            onExit: () => {
              this.closeAmapNaviPage();
            },
            // ★ 高德引擎截图出的帧 → 喂编码器 → 车机
            onFrame: (bmp: image.PixelMap, w: number, h: number) => {
              this.feedAmapFrame(bmp, w, h);
            }
          })
        }
        .width('100%')
        .height('100%')
        .id('amap_navi_root')       // ★ 截图目标（页面喂图模式）
      }

      // ★ 真地图页：MapViewComponent 原生渲染；需要显示到车机时由本页显式开启整屏投屏。
      //   ★ 小窗模式下不挂载（同上：地图实例唯一）。
      if (!this.floatMode && this.showRealMap) {
        Column() {
          MapPage({
            castActive: this.castRunning,
            onExit: () => {
              this.closeRealMapPage();
            },
            onToggleCast: () => {
              this.toggleRealMapCast();
            }
          })
        }
        .width('100%')
        .height('100%')
        .id('real_map_root')
      }

      // ★★ 系统小窗模式：整屏换成**纯地图**。
      //
      // 为什么必须换：这块画面会被采集送进车机。如果小窗里还是设置列表，
      // 车机看到的就是一堆开关和日志。所以 `floatMode` 时把整个界面让给地图。
      //
      // `chrome: false` 关掉顶部「返回设置 / 投屏到车机」操作栏 ——
      // 否则那两个按钮会一起出现在车机上。
      if (this.floatMode) {
        Column() {
          MapPage({
            chrome: false,
            castActive: this.castRunning,
            onExit: () => {
              // chrome=false 时页面上没有返回按钮，这里只是兜底
              CarLifeRuntime.addLog('[小窗] 地图页请求退出（忽略：请用系统手势还原窗口）');
            },
            onToggleCast: () => {
              this.toggleRealMapCast();
            }
          })
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#000000')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0A0C10')
    .id('hmi_root')            // ★ 同步截图目标（前台推流兜底用）
  }

  // ==================== 车机 HMI：左侧图标导航栏 ====================
  // 纯图标（无文字），112px 宽。三个入口：首页 / 导航 / 设置。
  // 按大哥要求：无「已连接」等状态文字，设置贴底。
  @Builder
  SideRail() {
    Column() {
      this.RailBtn(0, 'home')     // 首页
      this.RailBtn(1, 'navi')     // 导航
      Blank()                     // 把设置压到底部
      this.RailBtn(2, 'gear')     // 设置
    }
    .width(56)
    .height('100%')
    .padding({ top: 14, bottom: 14 })
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('#0A0C10')
    .border({ width: { right: 1 }, color: '#232A36' })
  }

  /**
   * 导航栏图标按钮。
   *
   * 图标用 SVG 资源（resources/base/media/ic_*.svg），灰/蓝两套随激活态切换。
   * ★ 不用 Path 手绘：Path 的 viewport/commands 尺寸对应关系容易出错
   *   （曾把图标画溢出按钮、两个图标叠在一起）。
   * ★ 不用 SymbolGlyph：sys.symbol 名称在 SDK 里查不到清单，赌名字不稳。
   */
  @Builder
  RailBtn(page: number, kind: string) {
    Column() {
      if (kind === 'home') {
        Image(this.page === page ? $r('app.media.ic_home_on') : $r('app.media.ic_home'))
          .width(24)
          .height(24)
      } else if (kind === 'navi') {
        Image(this.page === page ? $r('app.media.ic_navi_on') : $r('app.media.ic_navi'))
          .width(24)
          .height(24)
      } else {
        Image(this.page === page ? $r('app.media.ic_gear_on') : $r('app.media.ic_gear'))
          .width(24)
          .height(24)
      }
    }
    .width(44)
    .height(44)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(this.page === page ? '#1A3A5C' : Color.Transparent)
    .borderRadius(12)
    .margin({ bottom: 8 })
    .onClick(() => {
      this.page = page;
    })
  }

  // ==================== 车机 HMI：首页 ====================
  // 布局：中列（上=导航转向卡 / 下=音频迷你卡）+ 右侧纯地图。
  @Builder
  HomePage() {
    Row() {
      // ---------- 中列：440px ----------
      Column({ space: 14 }) {
        this.NavTurnCard()
        this.AudioMiniCard()
      }
      .width(220)
      .height('100%')
      .padding(14)
      .alignItems(HorizontalAlign.Center)

      // ---------- 右侧：纯地图 ----------
      this.MapArea()
    }
    .layoutWeight(1)
    .height('100%')
  }

  /** 导航转向卡（中列上块） */
  @Builder
  NavTurnCard() {
    Column() {
      Row() {
        // 转向箭头（蓝色圆底 + 箭头）
        Stack() {
          Circle({ width: 24, height: 24 }).fill('#1A3A5C')
          Text('↑')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor('#2E9BFF')
        }
        .margin({ right: 12 })

        Column() {
          Row() {
            Text(this.navDistance)
              .fontSize(28)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
            Text(this.navUnit)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor('#C3CBD9')
              .margin({ left: 3, bottom: 5 })
          }
          .alignItems(VerticalAlign.Bottom)

          Text(this.navRoad)
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .margin({ bottom: 6 })

      Text(this.navHint)
        .fontSize(13)
        .fontColor('#C3CBD9')
        .width('100%')

      Divider()
        .color('#232A36')
        .margin({ top: 6, bottom: 6 })

      Row() {
        Text('↰')
          .fontSize(11)
          .fontColor('#7C879B')
          .margin({ right: 7 })
        Text(this.navNext)
          .fontSize(11)
          .fontColor('#7C879B')
      }
      .width('100%')
    }
    .layoutWeight(1)
    .width('100%')
    .padding(16)
    .backgroundColor('#141821')
    .borderRadius(12)
    .border({ width: 1, color: '#232A36' })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Start)
  }

  /** 音频迷你卡（中列下块，常驻；音频不是独立页） */
  @Builder
  AudioMiniCard() {
    Column({ space: 8 }) {
      // 封面 + 曲目信息
      Row() {
        Stack() {
          Rect()
            .width(48)
            .height(48)
            .radius(8)
            .fill('#111722')
            .stroke('#232A36')
            .strokeWidth(1)
          Circle({ width: 24, height: 24 }).fill('#1A3A5C')
          Circle({ width: 9, height: 9 }).fill('#2E9BFF')
        }
        .margin({ right: 10 })

        Column({ space: 4 }) {
          Text(this.trackName)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.trackArtist)
            .fontSize(12)
            .fontColor('#C3CBD9')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      // 进度条
      Column({ space: 10 }) {
        Stack({ alignContent: Alignment.Start }) {
          Rect().width('100%').height(4).radius(2).fill('#1E2430')
          Rect()
            .width(`${this.progressRatio() * 100}%`)
            .height(8)
            .radius(4)
            .fill('#2E9BFF')
        }
        .width('100%')

        Row() {
          Text(this.fmtTime(this.progressSec))
            .fontSize(11)
            .fontColor('#7C879B')
          Blank()
          Text(this.fmtTime(this.durationSec))
            .fontSize(11)
            .fontColor('#7C879B')
        }
        .width('100%')
      }
      .width('100%')

      // 播放控制：上一首 / 播放暂停 / 下一首
      Row({ space: 12 }) {
        this.AudioBtn('⏮', 38, false, () => {
          CarLifeRuntime.addLog('[音频] 上一曲（待接媒体源）');
        })
        this.AudioBtn(this.playing ? '⏸' : '▶', 46, true, () => {
          this.playing = !this.playing;
          CarLifeRuntime.addLog(this.playing ? '[音频] 播放' : '[音频] 暂停');
        })
        this.AudioBtn('⏭', 38, false, () => {
          CarLifeRuntime.addLog('[音频] 下一曲（待接媒体源）');
        })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#141821')
    .borderRadius(12)
    .border({ width: 1, color: '#232A36' })
    .justifyContent(FlexAlign.Center)
  }

  /** 音频控制按钮（size 88 次级 / 112 主按钮） */
  @Builder
  AudioBtn(label: string, size: number, primary: boolean, action: () => void) {
    Button(label)
      .fontSize(primary ? 18 : 14)
      .width(size)
      .height(size)
      .borderRadius(999)
      .backgroundColor(primary ? '#2E9BFF' : '#1E2430')
      .fontColor(primary ? '#06131F' : '#FFFFFF')
      .border(primary ? { width: 0 } : { width: 1, color: '#232A36' })
      .onClick(action)
  }

  // ==================== 车机 HMI：导航页（纯地图） ====================
  @Builder
  MapOnlyPage() {
    this.MapArea()
  }

  // ==================== 车机 HMI：设置页 ====================
  // 上半 = 常规设置项；下半 = 诊断面板（原独立面板搬进来了）。
  // 整页可滚动，否则诊断内容在小窗口里放不下。
  @Builder
  SettingsPage() {
    Scroll() {
      Column({ space: 12 }) {
        Text('设置')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .width('100%')

        // ---------- 车机画面切换（手机端只显示设置，不预览 HMI） ----------
        Row({ space: 8 }) {
          Text('车机画面')
            .fontSize(13)
            .fontColor('#8B949E')
          Blank()
          Button('首页')
            .fontSize(12)
            .height(28)
            .backgroundColor(this.page === 0 ? '#1F6FEB' : '#21262D')
            .fontColor(this.page === 0 ? '#FFFFFF' : '#8B949E')
            .onClick(() => { this.page = 0; })
          Button('导航')
            .fontSize(12)
            .height(28)
            .backgroundColor(this.page === 1 ? '#1F6FEB' : '#21262D')
            .fontColor(this.page === 1 ? '#FFFFFF' : '#8B949E')
            .onClick(() => { this.page = 1; })
        }
        .width('100%')
        .padding(10)
        .backgroundColor('#161B22')
        .border({ width: 1, color: '#21262D', radius: 8 })
        .alignItems(VerticalAlign.Center)

        // ---------- 导航数据接入（高德 SDK）----------
        // Car Kit 路线已于 2026-10-16 判死并**整体移除**（见 core/NaviInfoProbe.ets 文件头）：
        // SDK 无读取接口 + 真机零回调 + 官方客服确认（根因是应用沙箱，第三方读不到别人的运行时数据）。
        // 现在只剩一条路：**在 CarHi 内自己用高德 SDK 发起导航** —— 数据自产自用，绕开沙箱。
        Column({ space: 8 }) {
          Text('导航数据接入（高德 SDK）')
            .fontSize(12)
            .fontColor('#8B949E')
            .width('100%')
          Text('在 CarHi 内用高德导航 SDK 自己发起导航，把 onNaviInfoUpdate 的数据'
            + '（转向/距离/路名/车道线）搬给车机渲染器。')
            .fontSize(10)
            .fontColor('#6E7681')
            .width('100%')

          // ★ 端到端：算路 + 模拟导航，验证 onNaviInfoUpdate 是否吐真实数据
          Button(this.naviProbeBusy ? '测试中…' : '▶ 高德导航端到端测试（模拟）')
            .fontSize(12)
            .height(30)
            .width('100%')
            .enabled(!this.naviProbeBusy)
            .backgroundColor(this.naviProbeBusy ? '#30363D' : '#238636')
            .fontColor('#FFFFFF')
            .onClick(() => {
              this.runNaviEndToEnd();
            })

          // ★★★ A3′：打开高德**原生**导航页（画面由高德渲染，不是我们手画）
          Button('🗺 打开高德原生导航页（画面由高德渲染）')
            .fontSize(12)
            .height(34)
            .width('100%')
            .backgroundColor('#8957E5')
            .fontColor('#FFFFFF')
            .onClick(() => {
              this.openAmapNaviPage();
            })

          Button('真地图预览（高德 MapView）')
            .fontSize(12)
            .height(34)
            .width('100%')
            .backgroundColor('#0F6CBD')
            .fontColor('#FFFFFF')
            .onClick(() => {
              this.openRealMapPage();
            })

          // ★★★★ 应用投屏：采集屏幕（可录到手机上的高德 App）→ 推车机
          //   与官方 CarLife 同机制（OH_AVScreenCapture）。首次会弹系统授权框，点「允许」即可。
          Button(this.castRunning ? '■ 停止应用投屏' : '📱 应用投屏（录屏推车机）')
            .fontSize(12)
            .height(34)
            .width('100%')
            .backgroundColor(this.castRunning ? '#DA3633' : '#0F6CBD')
            .fontColor('#FFFFFF')
            .onClick(() => {
              if (this.castRunning) {
                this.stopAppCast();
              } else {
                this.startAppCast();
              }
            })

          if (this.castText.length > 0) {
            Text(this.castText)
              .fontSize(11)
              .fontColor('#C9D1D9')
              .width('100%')
          }

          // ---- ★ 独立投屏窗口：主窗口保持设置页，另开一个 16:9 横屏窗口投地图 ----
          //   为什么不用悬浮窗：FLOAT_VIEW 是 system_basic 级权限，普通签名证书没有
          //   对应 ACL，声明即装机失败 9568289。子窗口**不需要任何权限**。
          Button(this.castWinOpen ? '🪟 关闭独立投屏窗口' : '🪟 独立投屏窗口（主窗口不变）')
            .fontSize(12)
            .height(34)
            .width('100%')
            .backgroundColor(this.castWinOpen ? '#DA3633' : '#238636')
            .fontColor('#FFFFFF')
            .onClick(() => {
              this.toggleCastWindow();
            })

          if (this.regionText.length > 0) {
            Text(this.regionText)
              .fontSize(11)
              .fontColor('#8B949E')
              .width('100%')
          }

          if (this.castWinOpen) {
            Text('车机只显示这个 16:9 独立窗口（地图），主窗口可继续操作设置。'
              + '切到其他 App 时该窗口会随应用一起不可见 —— 要真正浮在别人之上需系统级悬浮窗权限。')
              .fontSize(10)
              .fontColor('#8B949E')
              .width('100%')
          }

          // ---- ★★ 系统小窗投屏（2026-10-18）：靠系统手势拖成悬浮小窗 ----
          //   这是不需要任何权限就能"边用手机边投屏"的唯一路径。
          Column({ space: 3 }) {
            Text(this.floatMode
              ? '🪟 已进入系统小窗：界面切成 16:9 纯地图，车机只投这块'
              : '🪟 小窗投屏：用系统「智慧多窗」把本应用拖成悬浮小窗，会自动切 16:9 地图并只投这块')
              .fontSize(11)
              .fontColor(this.floatMode ? '#3FB950' : '#8B949E')
              .width('100%')
            if (this.floatMode) {
              Text('拖回全屏即恢复设置页与整屏采集。窗口大小可随意拖，采集区域会自动跟随。')
                .fontSize(10)
                .fontColor('#8B949E')
                .width('100%')
            } else {
              Text('前提：本应用已声明支持悬浮模式（module.json5 的 supportWindowMode）。')
                .fontSize(10)
                .fontColor('#6E7681')
                .width('100%')
            }
          }
          .width('100%')
          .padding({ top: 4, left: 8, right: 8, bottom: 4 })
          .backgroundColor('#0D1117')
          .border({ width: 1, color: this.floatMode ? '#238636' : '#21262D', radius: 6 })

          // ---- ★ 采集存活诊断（车机上直接看，不用连 USB）----
          //   判读：lastOut 一直涨 = 已断流；fps 长期为 0 = 已断流。
          if (this.castRunning) {
            Column({ space: 3 }) {
              this.DiagLine('出帧', `${this.castFrames} 帧 · ${this.castFps} fps`,
                this.castFps > 0 ? '#3FB950' : '#F85149')
              // ★ 长时任务挂起诊断（2026-10-16）：切后台再切回来，这一行直接告诉你
              //   "刚才是否被系统挂起、原因是什么" —— 无需连 hdc 抓日志。
              //   判读：显示「✔ 未发生挂起」= 掉线与长时任务无关，往别处查。
              this.DiagLine('保活', this.keeperDiag.length > 0 ? this.keeperDiag : '—',
                this.keeperDiag.startsWith('⚠') ? '#F85149' : '#3FB950')
              this.DiagLine('断流计时', this.castLastOutMs < 0
                ? '—'
                : `${(this.castLastOutMs / 1000).toFixed(1)} s`,
                this.castLastOutMs >= 0 && this.castLastOutMs < 2000 ? '#3FB950' : '#F85149')
              this.DiagLine('编码尺寸', this.castSize.length > 0 ? this.castSize : '—', '#8B949E')
              Text(this.castWatchdogText)
                .fontSize(10)
                .fontColor(this.castWatchdogText.startsWith('⚠') ? '#F85149' : '#6E7681')
                .width('100%')
            }
            .width('100%')
            .padding({ top: 6, left: 8, right: 8, bottom: 6 })
            .backgroundColor('#0D1117')
            .border({ width: 1, color: '#21262D', radius: 6 })
            .alignItems(HorizontalAlign.Start)
          }

          if (this.naviProbeText.length > 0) {
            Text(this.naviProbeText)
              .fontSize(11)
              .fontColor('#C9D1D9')
              .width('100%')
          }
        }
        .width('100%')
        .padding(10)
        .backgroundColor('#161B22')
        .border({ width: 1, color: '#21262D', radius: 8 })
        .alignItems(HorizontalAlign.Start)

        this.SettingRow('连接方式', 'Wi-Fi Direct')
        this.SettingRow('视频通道', '8240')
        this.SettingRow('音频通道', '9240')
        this.SettingRow('地图数据源', '待接入')

        // ---------- 诊断区（原右侧独立面板）----------
        Divider().color('#232A36').margin({ top: 8, bottom: 4 })

        Text('诊断')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#C3CBD9')
          .width('100%')

        // 状态
        Column({ space: 8 }) {
          Text('状态')
            .fontSize(12)
            .fontColor('#8B949E')
            .width('100%')
          this.StatusLine(this.running ? '服务运行中' : '服务已停止',
            this.running ? '#3FB950' : '#484F58')
          this.StatusLine(this.stateText, this.handshakeOk() ? '#3FB950' : '#484F58')
          this.StatusLine(`${this.keeperActive ? '保活生效' : '未保活'}`
            + ` · ${this.backgrounded ? '已切后台' : '前台'}`,
            this.keeperActive ? '#3FB950' : '#D29922')
          Text(this.statusMessage)
            .fontSize(10)
            .fontColor('#6E7681')
            .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(10)
        .backgroundColor('#161B22')
        .border({ width: 1, color: '#21262D', radius: 8 })

        // 服务开关
        Button(this.running ? '停止服务' : '启动服务')
          .fontSize(13)
          .height(34)
          .width('100%')
          .backgroundColor(this.running ? '#DA3633' : '#238636')
          .fontColor('#FFFFFF')
          .onClick(() => {
            this.toggleService();
          })

        // 推流
        Row() {
          this.StatItem('帧率', `${this.fps}`)
          this.StatItem('kbps', `${this.kbps}`)
          this.StatItem('帧数', `${this.frameTotal}`)
        }
        .width('100%')
        .padding(10)
        .backgroundColor('#161B22')
        .border({ width: 1, color: '#21262D', radius: 8 })

        // ---------- 自绘诊断（路线 A1）----------
        Column({ space: 8 }) {
          Text('自绘诊断')
            .fontSize(12)
            .fontColor('#8B949E')
            .width('100%')
          Text(this.hmiDiagText)
            .fontSize(11)
            .fontColor(this.hmiFallback ? '#D29922'
              : (this.hmiBackend === 1 ? '#58A6FF' : '#3FB950'))
            .width('100%')
          Text(this.hmiFallback
            ? '⚠ 自绘未起来，已回落截图推流（仅前台有效，切后台会冻结）'
            : (this.hmiBackend === 1
              ? 'CPU 位图后端 → GL 上传（稳定，帧率略低）'
              : 'GPU OnScreen 后端（零拷贝；若黑屏请切 CPU）'))
            .fontSize(10)
            .fontColor('#6E7681')
            .width('100%')

          Text('渲染后端')
            .fontSize(11)
            .fontColor('#8B949E')
            .width('100%')
          Row({ space: 6 }) {
            this.BackendBtn('自动', HMI_BACKEND_AUTO)
            this.BackendBtn('GPU', HMI_BACKEND_GPU)
            this.BackendBtn('CPU', HMI_BACKEND_CPU)
          }
          .width('100%')

          Button('强制重建画面通路')
            .fontSize(12)
            .height(30)
            .width('100%')
            .backgroundColor('#30363D')
            .fontColor('#C9D1D9')
            .onClick(() => {
              // 黑屏自救：停掉再起，重新走一遍后端探测（含自愈）
              CarLifeRuntime.addLog('[自绘] 用户请求重建画面通路');
              EngineHolder.stop();
              this.running = false;
              this.stopFallbackPush();
              this.startService().catch((e: Error) => {
                CarLifeRuntime.addLog(`重建失败: ${e.message}`);
              });
            })

          Button(this.hmiSelfTest ? '停止自测' : '自绘自测（不需车机）')
            .fontSize(12)
            .height(30)
            .width('100%')
            .backgroundColor(this.hmiSelfTest ? '#DA3633' : '#238636')
            .fontColor('#FFFFFF')
            .onClick(() => {
              this.toggleSelfTest();
            })
          Text('自测会直接启动编码器与自绘渲染，用上面的数字判断通路是否出帧。')
            .fontSize(10)
            .fontColor('#6E7681')
            .width('100%')

          // ---- 离线自检：绕过编码器，只验渲染器 ----
          // 为什么要有它：模拟器（以及部分无编码器的环境）连上面那个自测都
          // 起不来，但"画得出来吗"跟编码器无关。
          Button(this.hmiCheckBusy ? '自检中…' : '离线自检（不碰编码器）')
            .fontSize(12)
            .height(30)
            .width('100%')
            .enabled(!this.hmiCheckBusy)
            .backgroundColor(this.hmiCheckBusy ? '#30363D' : '#8957E5')
            .fontColor('#FFFFFF')
            .onClick(() => {
              this.runOfflineSelfCheck();
            })
          Text('用 CPU 位图后端把首页/导航页各画一遍，返回绘制耗时并落成 PNG'
            + '（files/hmi_home.png、files/hmi_navi.png）。')
            .fontSize(10)
            .fontColor('#6E7681')
            .width('100%')
          if (this.hmiCheckText.length > 0) {
            Text(this.hmiCheckText)
              .fontSize(11)
              .fontColor('#C9D1D9')
              .width('100%')
          }
        }
        .width('100%')
        .padding(10)
        .backgroundColor('#161B22')
        .border({ width: 1, color: '#21262D', radius: 8 })
        .alignItems(HorizontalAlign.Start)

        // ---------- 前台截图测速（前台推流方案验证）----------
        Column({ space: 8 }) {
          Text('前台截图测速')
            .fontSize(12)
            .fontColor('#8B949E')
            .width('100%')
          Text('测「同步截取当前界面」的耗时 —— 决定前台能否支撑 30fps 推流。')
            .fontSize(10)
            .fontColor('#6E7681')
            .width('100%')

          Button(this.probeRunning ? '测试中…' : '开始测速（20 次）')
            .fontSize(13)
            .height(34)
            .width('100%')
            .enabled(!this.probeRunning)
            .backgroundColor(this.probeRunning ? '#30363D' : '#1F6FEB')
            .fontColor('#FFFFFF')
            .onClick(() => {
              this.runOffscreenProbe();
            })

          if (this.probeResult.length > 0) {
            Text(this.probeResult)
              .fontSize(11)
              .fontColor('#C9D1D9')
              .width('100%')
          }
        }
        .width('100%')
        .padding(10)
        .backgroundColor('#161B22')
        .border({ width: 1, color: '#21262D', radius: 8 })
        .alignItems(HorizontalAlign.Start)

        // 通道
        Column({ space: 6 }) {
          Text(`通道 ${this.connectedChannelCount()}/${ALL_CHANNELS.length}`)
            .fontSize(12)
            .fontColor('#8B949E')
            .width('100%')
          Row() {
            ForEach(ALL_CHANNELS, (def: ChannelDef, idx: number) => {
              Column({ space: 4 }) {
                Circle({ width: 6, height: 6 })
                  .fill(this.channelConnected[idx] ? '#3FB950' : '#30363D')
                Text(`${def.port}`)
                  .fontSize(9)
                  .fontColor(this.channelConnected[idx] ? '#3FB950' : '#6E7681')
              }
              .layoutWeight(1)
            }, (def: ChannelDef) => `${def.channel}`)
          }
          .width('100%')
        }
        .width('100%')
        .padding(10)
        .backgroundColor('#161B22')
        .border({ width: 1, color: '#21262D', radius: 8 })
        .alignItems(HorizontalAlign.Start)

        // Wi-Fi 直连
        WifiDirectCard()

        // 运行日志
        Column({ space: 8 }) {
          Text('运行日志')
            .fontSize(12)
            .fontColor('#8B949E')
            .width('100%')
          Scroll(this.scroller) {
            Column({ space: 2 }) {
              ForEach(this.logs, (line: string) => {
                Text(line)
                  .fontSize(10)
                  .fontColor('#8B949E')
                  .fontFamily('monospace')
                  .width('100%')
                  .textAlign(TextAlign.Start)
              }, (line: string, idx: number) => `${idx}_${line}`)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
          .height(200)
          .width('100%')
          .scrollBar(BarState.Off)
        }
        .width('100%')
        .padding(10)
        .backgroundColor('#161B22')
        .border({ width: 1, color: '#21262D', radius: 8 })
        .alignItems(HorizontalAlign.Start)

        Text('CarHi · 手机端 CarLife')
          .fontSize(12)
          .fontColor('#4A5364')
          .margin({ top: 8 })
      }
      .width('100%')
      .padding(24)
      .alignItems(HorizontalAlign.Start)
    }
    .layoutWeight(1)
    .height('100%')
    .backgroundColor('#0A0C10')
    .scrollBar(BarState.Auto)
  }

  /** 设置项行 */
  @Builder
  SettingRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(14)
        .fontColor('#C3CBD9')
      Blank()
      Text(value)
        .fontSize(14)
        .fontColor('#7C879B')
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .border({ width: { bottom: 1 }, color: '#232A36' })
  }

  // ==================== 车机 HMI：地图区（纯地图，无浮层） ====================
  // 按大哥要求：地图上不放时间、不放行程卡、不放 FAB，保持绝对干净。
  @Builder
  MapArea() {
    Stack() {
      // 路网骨架（占位；真实地图待接高德/花瓣 SDK）
      Column() {
        ForEach([0, 1, 2, 3, 4, 5, 6, 7, 8, 9], (i: number) => {
          Divider().color('#161C26').strokeWidth(3).margin({ top: 30 })
        }, (i: number) => `h${i}`)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Start)

      Column() {
        Row() {
          ForEach([0, 1, 2, 3, 4, 5, 6, 7], (i: number) => {
            Divider()
              .vertical(true)
              .color('#161C26')
              .strokeWidth(3)
              .height('100%')
              .layoutWeight(1)
          }, (i: number) => `v${i}`)
        }
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .height('100%')

      // 占位提示
      Column({ space: 8 }) {
        Text('地图区域')
          .fontSize(14)
          .fontColor('#30363D')
        Text('待接高德 / 花瓣地图 SDK')
          .fontSize(11)
          .fontColor('#232A36')
      }
    }
    .layoutWeight(1)
    .height('100%')
    .backgroundColor('#0E1219')
  }

  // ============================== 小组件 ==============================
  @Builder
  StatusLine(text: string, color: string) {
    Row() {
      Circle({ width: 7, height: 7 }).fill(color)
      Text(text)
        .fontSize(12)
        .fontColor(color)
        .margin({ left: 6 })
    }
    .width('100%')
  }

  @Builder
  StatItem(label: string, value: string) {
    Column({ space: 3 }) {
      Text(value)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor('#E6EDF3')
      Text(label)
        .fontSize(10)
        .fontColor('#6E7681')
    }
    .layoutWeight(1)
  }

  /**
   * 渲染后端切换按钮。
   *
   * 高亮判据：当前后端与按钮目标一致（AUTO 只在既非 CPU 也非兜底时高亮）。
   * 黑屏自救入口 —— 点「CPU」即可切到已验证的 GL 上传通路。
   */
  @Builder
  BackendBtn(label: string, backend: number) {
    Button(label)
      .fontSize(11)
      .height(28)
      .layoutWeight(1)
      .backgroundColor(this.hmiBackendReq === backend ? '#1F6FEB' : '#21262D')
      .fontColor(this.hmiBackendReq === backend ? '#FFFFFF' : '#8B949E')
      .onClick(() => {
        this.switchHmiBackend(backend);
      })
  }

  // ============================== 逻辑 ==============================
  /** 车机渲染器当前页面名（诊断面板显示用） */
  private pageName(): string {
    return this.page === 1 ? '导航页' : '首页';
  }

  /**
   * 高德导航**端到端测试**：初始化 → 算路 → 模拟导航 → 看数据是否真的在流。
   *
   * 为什么用**模拟导航**：不用真开车，SDK 按虚拟速度走完全程，
   * `onNaviInfoUpdate` 会持续吐真实数据 —— 是验证「数据→渲染→推车机」
   * 链路的最快手段（等真实开车太慢，且没法在桌面上重复）。
   *
   * 终点用默认测试点（天安门），因为不依赖当前位置。
   */
  private async runNaviEndToEnd(): Promise<void> {
    this.naviProbeBusy = true;
    this.naviProbeText = '端到端测试中…（算路约 14s + 数据观察 8s）';
    try {
      // 天安门（高德 GCJ-02 坐标）
      const text: string = await NaviInfoProbe.runNaviTest(39.908722, 116.397499, true);
      this.naviProbeText = text;
    } catch (e) {
      const err = e as Error;
      this.naviProbeText = `端到端测试异常：${err.message}`;
    }
    this.naviProbeBusy = false;
  }

  /** 播放进度比例（0~1） */
  private progressRatio(): number {
    if (this.durationSec <= 0) {
      return 0;
    }
    const r: number = this.progressSec / this.durationSec;
    return r < 0 ? 0 : (r > 1 ? 1 : r);
  }

  /** 秒 → m:ss */
  private fmtTime(sec: number): string {
    const s: number = Math.max(0, Math.floor(sec));
    const m: number = Math.floor(s / 60);
    const r: number = s % 60;
    return `${m}:${r < 10 ? '0' : ''}${r}`;
  }

  private handshakeOk(): boolean {
    return this.stateText !== '未连接' && this.stateText !== '';
  }

  private connectedChannelCount(): number {
    let n: number = 0;
    for (let i = 0; i < this.channelConnected.length; i++) {
      if (this.channelConnected[i]) {
        n++;
      }
    }
    return n;
  }

  /**
   * 跑路线 A 的机制验证：往编码器自己的输入 surface 画 → 能否出帧。
   *
   * 为什么需要：A2（XComponent surfaceId 交给编码器）已证伪；A1/β 两条路的
   * 共同地基是「能往编码器 surface 写」。这个按钮就是验证地基。
   *
   * 注意：native 侧是**同步阻塞**的（跑 3 秒），所以按钮要禁用 + 提示。
   */
  /**
   * 前台推流测速：测「同步截图当前界面」的真实耗时。
   *
   * ## 为什么改测这个
   *
   * 原计划「离屏渲染」（createFromBuilder）实测 **345ms/帧 ≈ 2fps**，已否决 ——
   * 它每次都要重建组件树，开销是架构性的。
   *
   * 但**前台**情况完全不同：界面本来就挂在树上、系统正在渲染它，
   * 此时用 `getSync(id)` 是**同步**取一张现成的快照，不用重建任何东西，
   * 理论上快到能支撑 30fps。
   *
   * 代价：只在**前台**可用（切后台系统停渲染就没了）。
   * 先用它把「ArkUI 界面 → 编码器 → 车机显示」这条通路验证通。
   */
  private runOffscreenProbe(): void {
    if (this.probeRunning) {
      return;
    }
    this.probeRunning = true;
    this.probeResult = '正在测前台同步截图耗时…';

    const N: number = 20;
    const costs: number[] = [];
    const ctx = this.getUIContext();
    let ok: number = 0;
    let fail: number = 0;

    for (let i = 0; i < N; i++) {
      const t0: number = Date.now();
      try {
        const pm = ctx.getComponentSnapshot().getSync('hmi_root');
        const cost: number = Date.now() - t0;
        costs.push(cost);
        ok++;
        pm.release();
      } catch (e) {
        fail++;
      }
    }

    if (costs.length === 0) {
      this.probeResult = `✗ 全部失败（${fail} 次）。检查根容器是否设了 .id('hmi_root')`;
      this.probeRunning = false;
      return;
    }

    let sum: number = 0;
    let min: number = 1e9;
    let max: number = 0;
    for (const c of costs) {
      sum += c;
      if (c < min) {
        min = c;
      }
      if (c > max) {
        max = c;
      }
    }
    const avg: number = Math.round(sum / costs.length);
    const fps: number = avg > 0 ? Math.floor(1000 / avg) : 0;
    const lines: string[] = [];
    lines.push(`前台同步截图 ${costs.length} 次（失败 ${fail}）：`);
    lines.push(`平均 ${avg}ms ／ 最小 ${Math.round(min)}ms ／ 最大 ${Math.round(max)}ms`);
    lines.push(`推算上限 ≈ ${fps} fps`);
    lines.push(avg <= 34 ? '✅ 可支撑 30fps' : (avg <= 50 ? '⚠ 够 20fps' : `⚠ 只够 ${fps}fps`));
    this.probeResult = lines.join('\n');
    CarLifeRuntime.addLog(`[前台截图] ok=${ok} fail=${fail} avg=${avg}ms min=${Math.round(min)} max=${Math.round(max)}`);
    this.probeRunning = false;
  }

  /** 离屏渲染用的测试帧（尺寸与车机期望一致 1280×720 的逻辑等价） */
  @Builder
  ProbeFrame(idx: number) {
    Column() {
      Text(`离屏测试帧 #${idx}`)
        .fontSize(28)
        .fontColor('#FFFFFF')
      Text('1280 × 720')
        .fontSize(20)
        .fontColor('#2E9BFF')
    }
    .width(320)
    .height(180)
    .backgroundColor('#0A0C10')
    .justifyContent(FlexAlign.Center)
  }

  private runProbe(): void {
    if (this.probeRunning) {
      return;
    }
    // 编码器是独占资源：先停掉正在跑的服务，避免两个实例打架
    if (this.running) {
      this.probeResult = '⚠ 请先「停止服务」再验证（编码器是独占资源）';
      return;
    }
    this.probeRunning = true;
    this.probeResult = '正在验证（约 3 秒）...';

    // 用 setTimeout 让 UI 先把「正在验证」画出来，再进阻塞调用
    setTimeout(() => {
      try {
        const r = carlifecodec.runPipelineProbe(1280, 720, 3);
        const lines: string[] = [];
        lines.push(r.ok ? '✅ 机制成立：能出帧' : '❌ 机制不通：一帧没出');
        lines.push(`阶段走到：${r.stage}`);
        lines.push(`编码器：${r.encWidth}x${r.encHeight}`);
        lines.push(`surfaceId：${r.surfaceIdOk ? '已取到 ' + r.surfaceId : '取不到'}`);
        lines.push(`EGL：display=${r.eglOk ? 'OK' : 'FAIL'}`
          + ` surface=${r.eglSurfaceOk ? 'OK' : 'FAIL'}`);
        lines.push(`喂进(swap)：${r.swapCount} 帧`);
        lines.push(`编码器吐出：${r.outputFrames} 帧`);
        if (r.firstOutputPts >= 0) {
          lines.push(`首帧 pts：${r.firstOutputPts}`);
        }
        if (r.error.length > 0) {
          lines.push(`错误：${r.error}`);
        }
        this.probeResult = lines.join('\n');
        CarLifeRuntime.addLog(`[验证] ${r.ok ? '✅ 通' : '❌ 不通'} `
          + `swap=${r.swapCount} out=${r.outputFrames} stage=${r.stage}`);
      } catch (e) {
        const err = e as Error;
        this.probeResult = `✗ 验证异常：${err.message}`;
        CarLifeRuntime.addLog(`[验证] 异常：${err.message}`);
      } finally {
        this.probeRunning = false;
      }
    }, 50);
  }

  private async toggleService(): Promise<void> {
    if (this.running) {
      this.stopService();
      return;
    }
    await this.startService();
  }

  private stopService(): void {
    EngineHolder.stop();
    this.stopFallbackPush();
    this.running = false;
    this.stateText = '未连接';
    this.statusMessage = '服务已停止';
    CarLifeRuntime.addLog('服务已停止（可再次点击「启动服务」恢复）');
  }

  private async startService(): Promise<void> {
    if (EngineHolder.isRunning) {
      this.running = true;
      this.statusMessage = '已监听全部端口，请让车机发起连接';
      return;
    }
    this.statusMessage = '正在启动...';

    const listener: EngineListener = {
      onStateChange: (state: HandshakeState) => {
        this.stateText = stateName(state);
      },
      onLog: (text: string) => {
        CarLifeRuntime.addLog(text);
      },
      onChannelChange: (channel: number, connected: boolean) => {
        const next = this.channelConnected.slice();
        const idx = ALL_CHANNELS.findIndex((d: ChannelDef) => d.channel === channel);
        if (idx >= 0 && idx < next.length) {
          next[idx] = connected;
          this.channelConnected = next;
        }
      },
      onStats: (fps: number, kbps: number, frames: number) => {
        this.fps = fps;
        this.kbps = kbps;
        this.frameTotal = frames;
      }
    };

    try {
      await EngineHolder.start(listener);
      this.running = true;
      this.statusMessage = '已监听全部端口，请让车机发起连接';
      // ★ 车机画面：native 自绘（HmiRenderer 起在编码器输入 surface 上）。
      //   这里只推一次初始状态；之后由 300ms 轮询里的 syncHmi() 持续同步。
      this.syncHmi();
    } catch (e) {
      const err = e as Error;
      this.statusMessage = `启动失败: ${err.message}`;
      CarLifeRuntime.addLog(`启动失败: ${err.message}`);
    }
  }

  // ==================== 车机画面状态同步（路线 A1）====================
  /**
   * 把 ArkUI 侧当前 HMI 状态推给 native 自绘渲染器。
   *
   * ★ 2026-10-14 架构变更：这里原来是「30fps 截图 → pushFrame」的前台推流循环。
   *   它已被 NativeHmiSource（native 自绘）取代，原因：
   *     1. getSync 截图 ~26ms/帧，且**切后台系统停渲染** → 画面冻结；
   *     2. 每帧一次 14MB RGBA 拷贝；
   *     3. 离屏快照 createFromBuilder 实测 345ms/帧（≈2fps），不可用。
   *   现在 ArkTS 只负责「推状态」，画面由 native 自己的渲染线程产出。
   *
   * 设置页（page=2）是手机侧独有的，车机上保持显示首页。
   */
  /**
   * ★ A3′：把高德**引擎截图**的帧喂给编码器。
   *
   * 这是 A3′ 的画面通路最后一环：
   *   高德地图引擎（`map.getMapScreenShot()`）
   *     → PixelMap（纯导航画面）
   *     → 这里转 RGBA
   *     → `feedScreenshot()` → `PushPixels()` → 编码器 → 车机
   *
   * ★ 与「组件截图」的区别：本方法的输入来自**地图引擎内部**，
   *   不含 ArkUI 外壳、分辨率可控、官方支持（为 HUD/车机场景设计）。
   */
  private feedAmapFrame(bmp: image.PixelMap, w: number, h: number): void {
    const src = EngineHolder.frameSource;
    if (src === null || !src.isRunning) {
      return;
    }

    // ★★ 必须先缩放到编码器尺寸 —— 这是踩出来的硬约束：
    //
    //   高德引擎截图给的是**手机全屏尺寸**（1272×2860）。若直接把它喂进编码器，
    //   `CanvasEncoder::PushPixels()` 会为它重新分配一张 1272×2860 的 GL 纹理，
    //   而 **2860 的高度超出 GPU 纹理上限** → 触发 `EGL_CONTEXT_LOST(0x300D)`，
    //   表现为：返回值 `-13301`（= -1000 - 12301），前 2 帧成功后全部丢帧。
    //
    //   （`canvas_encoder.cpp` 里明确写了编码规则 `-1000 - eglGetError()`，
    //     12301 = 0x300D = EGL_CONTEXT_LOST。2026-10-15 真机定位。）
    const tw: number = src.canvasWidth;
    const th: number = src.canvasHeight;
    if (tw <= 0 || th <= 0) {
      return;
    }

    try {
      // 缩放（等比填充：取较大的缩放比，保证铺满，多余部分由 PushPixels 的
      // 纹理映射裁掉）。用较大的比才能避免出现黑边。
      if (w !== tw || h !== th) {
        const kx: number = tw / w;
        const ky: number = th / h;
        const k: number = Math.max(kx, ky);
        if (Math.abs(k - 1.0) > 0.001) {
          bmp.scaleSync(k, k);
        }
      }
    } catch (e) {
      const err = e as Error;
      if (!this.amapFrameErrLogged) {
        this.amapFrameErrLogged = true;
        CarLifeRuntime.addLog(`[引擎截图] 缩放失败: ${err.message}`);
      }
      return;
    }

    // 缩放后重新取尺寸
    let sw: number = tw;
    let sh: number = th;
    try {
      const info2 = bmp.getImageInfoSync();
      sw = info2.size.width;
      sh = info2.size.height;
    } catch (e) {
      // 取不到就用目标尺寸
    }

    const bytes: number = bmp.getPixelBytesNumber();
    if (bytes < sw * sh * 4) {
      if (!this.amapFrameErrLogged) {
        this.amapFrameErrLogged = true;
        CarLifeRuntime.addLog(`[引擎截图] ✗ 不是 RGBA8888（${sw}x${sh}, ${bytes} 字节）`);
      }
      return;
    }
    if (this.fallbackBuf === null || this.fallbackBuf.byteLength !== bytes) {
      this.fallbackBuf = new ArrayBuffer(bytes);
    }
    try {
      bmp.readPixelsToBufferSync(this.fallbackBuf);
      src.feedScreenshot(this.fallbackBuf, sw, sh);
      if (!this.amapFrameLogged) {
        this.amapFrameLogged = true;
        CarLifeRuntime.addLog(`[引擎截图] ★ 首帧已推给车机：${w}x${h} → 缩放 ${sw}x${sh}`);
      }
      // ★ 诊断：每秒报一次喂帧状态（含 pushFrame 返回码与跳过原因）
      const nowSec: number = Math.floor(Date.now() / 1000);
      if (nowSec !== this.amapFeedLogSec) {
        this.amapFeedLogSec = nowSec;
        CarLifeRuntime.addLog(`[引擎截图] 喂帧诊断：成功${NativeHmiSource.feedOkCount}次`
          + ` 返回码=${NativeHmiSource.lastFeedCode}`
          + ` 尺寸=${sw}x${sh}`);
      }
    } catch (e) {
      const err = e as Error;
      if (!this.amapFrameErrLogged) {
        this.amapFrameErrLogged = true;
        CarLifeRuntime.addLog(`[引擎截图] 取像素失败: ${err.message}`);
      }
    }
  }

  /**
   * ★ 应用投屏：采集屏幕 → 推车机。
   *
   * ## 机制
   * 与官方 CarLife 同（鸿蒙 `OH_AVScreenCapture` / 安卓 `MediaProjection`），
   * **普通应用即可用**，首次会弹系统录屏授权框（点「允许」）。
   *
   * ## 实现要点：采集与自绘是同一个编码器，必须互斥
   * 推流链路的画面源由 `EngineHolder.setFrameSourceFactory()` 决定。
   * 这里把工厂**换成采集源**，车机会重新走一遍「启动推流」——
   * 于是画面从「我们自绘的卡片」变成「手机真实屏幕」。
   *
   * ⚠ 必须在车机**已连接**时切换才有效（推流管线是车机下发 98313 才启动的）。
   */
  private startAppCast(): void {
    if (this.castSrc === null) {
      this.castSrc = new ScreenCaptureSource();
    }
    const src = this.castSrc;

    // 把画面源工厂换成采集源，并请引擎用同一套参数重启画面管线
    EngineHolder.setForceCaptureSource(src);
    const engine = EngineHolder.engine;
    if (engine === null) {
      this.castText = '服务未启动，请先启动服务';
      this.castRunning = false;
      CarLifeRuntime.addLog('[投屏] 服务未启动，无法切换画面源');
      return;
    }

    // ★ 没有车机时也允许启动采集 —— 用于**本地验证采集通路**
    //   （出帧就说明采集/编码没问题，与车机无关）。有车机时走完整切换流程。
    const ok: boolean = engine.switchFrameSource();
    if (ok) {
      this.castRunning = true;
      this.castText = '投屏中：手机屏幕正在推给车机（含高德等任意 App）';
    } else {
      // 无车机：直接本地起采集，只统计帧数
      CarLifeRuntime.addLog('[投屏] 无推流管线，改为本地验证采集');
      const localOk: boolean = src.startWith(1280, 720, 30,
        (nalu: Uint8Array, pts: number, keyFrame: boolean): void => {
          // ★ 本地验证也要打点 —— 否则诊断面板永远是 0，看不出"到底有没有出帧"
          this.onCastFrame(nalu, pts, keyFrame);
        },
        (code: number, msg: string): void => {
          this.castText = `采集出错 code=${code}：${msg}`;
          this.castRunning = false;
          this.stopCastWatchdog();
        });
      this.castRunning = localOk;
      this.castText = localOk
        ? '本地采集已启动（未连车机，帧只统计不上车）'
        : `采集启动失败：${src.diag().lastErrorMsg}`;
    }
    CarLifeRuntime.addLog(`[投屏] 启动结果 ok=${ok} castRunning=${this.castRunning}`);
    if (this.castRunning) {
      this.startCastWatchdog();
      // ★ 小窗模式：投屏一启动就把采集区域锁到「当前窗口」。
      //   必须在采集真正起来之后调用（native 侧要求 capture 实例已 Init）。
      if (this.regionOnly) {
        this.applyRegionFromWindow();
      }
    }
    AppStorage.setOrCreate<boolean>('carhiFloatOn', this.castRunning);
  }

  // ================= ★ 小窗投屏：只投本应用窗口那一块 =================
  //
  // 原理：`OH_AVScreenCapture_SetCaptureArea`（API 20+）可以只采集屏幕上的一块矩形。
  // 用户用系统「智慧多窗」把本应用拖成悬浮小窗后，把该小窗的 `windowRect` 交给
  // 采集器，车机就只看到这块内容，手机其余部分照常使用其他 App。
  //
  // ⚠ 应用**自己开不了**全局悬浮窗（FLOAT_VIEW 等权限要求系统应用，实测声明后
  //   装机直接失败 9568289），所以「小窗」只能由用户手动拖出来 —— 这不是缺陷，
  //   是权限边界。全屏时开本功能等于整屏采集（区域 = 整屏），不会有副作用。

  /** 把当前窗口矩形下发给采集器（采集未就绪时 native 会缓存，下次启动生效） */
  private async applyRegionFromWindow(): Promise<void> {
    const src = this.castSrc;
    if (src === null) {
      this.regionText = '尚未创建采集源（请先开始投屏）';
      return;
    }
    try {
      const win: window.Window = await window.getLastWindow(getContext(this));
      const rect: window.Rect = win.getWindowProperties().windowRect;
      const ret: number = src.setCaptureArea(rect.left, rect.top, rect.width, rect.height);
      if (ret === 0 || ret === -2) {
        this.regionText = `只投 ${Math.round(rect.width)}x${Math.round(rect.height)}`
          + ` @(${Math.round(rect.left)},${Math.round(rect.top)})`
          + (ret === -2 ? '（采集未就绪，已缓存）' : '');
      } else {
        this.regionText = `区域设置失败 ret=${ret}（设备可能不支持区域采集）`;
        CarLifeRuntime.addLog(`[小窗投屏] ${this.regionText}`);
      }
    } catch (e) {
      const err = e as Error;
      this.regionText = `取窗口矩形失败：${err.message}`;
      CarLifeRuntime.addLog(`[小窗投屏] ${this.regionText}`);
    }
  }

  /**
   * ★ 小窗横屏：把悬浮小窗调成 16:9 横屏，与车机 1280×720 同比例。
   *
   * 为什么必须等 FLOATING：`window.resize()` / `moveWindowTo()` 的官方语义是
   * **只在悬浮窗（FLOATING）模式下生效**，主窗口全屏时调用直接报 1300002。
   * 而普通应用**无法自己**把主窗口变成悬浮窗（`FLOAT_VIEW` 等权限要求系统应用，
   * 声明后装机失败 9568289），所以这一步的前提是用户先用系统「智慧多窗」
   * 把本应用拖成小窗 —— 拖好之后本方法会自动接管。
   *
   * 做成 16:9 的意义：区域采集的宽高比与车机画布一致 ⇒ **不变形、无黑边**，
   * 也就绕开了 `StrategyForFillMode` 的取舍。
   */
  private async applySmallWindowLandscape(): Promise<void> {
    try {
      const win: window.Window = await window.getLastWindow(getContext(this));
      const status: window.WindowStatusType = win.getWindowStatus();
      if (status !== window.WindowStatusType.FLOATING) {
        this.regionText = '请先用系统「智慧多窗」把本应用拖成悬浮小窗，再打开本开关';
        CarLifeRuntime.addLog(`[小窗投屏] 窗口状态=${status}（非悬浮窗），跳过横屏设置`);
        // 全屏时区域即整屏，等价于不限制，但仍然下发一次保持状态一致
        this.applyRegionFromWindow();
        return;
      }

      // ① 内容横屏 —— 方向由运行期代码控制，module.json5 的 orientation 不生效
      await win.setPreferredOrientation(window.Orientation.LANDSCAPE);

      // ② 调成 16:9。
      //   ⚠ 基准必须取**屏幕短边**：`setPreferredOrientation` 之后 display 的
      //   width/height 可能已按横屏互换，直接用 width 会算出一个几乎占满
      //   整屏（甚至超过屏幕高度）的"小窗"。
      const d: display.Display = display.getDefaultDisplaySync();
      const shortSide: number = Math.min(d.width, d.height);
      const targetW: number = Math.round(shortSide * 0.9);
      const targetH: number = Math.round(targetW * 9 / 16);
      let sized: boolean = false;
      try {
        await win.resize(targetW, targetH);
        sized = true;
      } catch (e) {
        const err = e as Error;
        CarLifeRuntime.addLog(`[小窗投屏] resize(${targetW}x${targetH}) 未生效：${err.message}`);
      }

      if (sized) {
        try {
          // 挪到左上方，避开状态栏和底部手势区
          await win.moveWindowTo(0, Math.round(shortSide * 0.1));
        } catch (e) {
          // 移动失败不影响采集（区域会按实际 windowRect 走）
        }
      }

      this.regionText = sized
        ? `小窗已横屏 ${targetW}x${targetH}（16:9）`
        : `小窗已横屏（尺寸由系统决定）`;
      CarLifeRuntime.addLog(`[小窗投屏] ${this.regionText}`);

      // ③ 区域跟着新窗口走
      this.applyRegionFromWindow();
    } catch (e) {
      const err = e as Error;
      this.regionText = `小窗横屏失败：${err.message}`;
      CarLifeRuntime.addLog(`[小窗投屏] ${this.regionText}`);
    }
  }

  /** 恢复竖屏（退出小窗投屏时调用；EntryAbility 启动时设的就是竖屏） */
  private async restorePortrait(): Promise<void> {
    try {
      const win: window.Window = await window.getLastWindow(getContext(this));
      await win.setPreferredOrientation(window.Orientation.PORTRAIT);
      CarLifeRuntime.addLog('[小窗投屏] 已恢复竖屏');
    } catch (e) {
      CarLifeRuntime.addLog('[小窗投屏] 恢复竖屏失败（忽略）');
    }
  }

  // ================= ★ 独立投屏窗口（主窗口保持设置页） =================
  //
  // 为什么用子窗口：`window.resize()` / `moveWindowTo()` 只在 FLOATING 模式生效，
  // 主窗口全屏时调用报 1300002；而 `WindowStage.createSubWindowWithOptions()`
  // 是普通应用可用的能力，`SubWindowOptions.windowRect` 能在**创建时**直接
  // 指定位置尺寸 —— 一次做成 16:9，完全不依赖 resize。
  //
  // ⚠ 子窗口仍属本应用：切到其他 App 时整个应用不可见，区域采集会录到
  //   "盖在这块区域上的别的内容"。要浮在别人之上需系统悬浮窗权限（已判死）。

  // ================= ★ 系统级悬浮窗（floatView）—— 能浮在其他 App 之上 =================
  //
  // 这是大哥真正要的能力。与此前的判断不同：`floatView` 是 HarmonyOS 26 的官方
  // ArkUI 能力，**不是** `window.createWindow(TYPE_FLOAT)` 那条需要系统签名的老路。
  // 它能加载**任意 ArkUI 页面**（`setUIContext(path)`），所以地图放得进去。
  //
  // 权限现实（`PermissionDefinitions.json` 实证）：
  //   - `floatView.create()`  → 无权限要求
  //   - `floatView.start()`   → 需要 `ohos.permission.FLOAT_VIEW`
  //   - `floatView.bind()`    → 还需 `ohos.permission.USE_FLOAT_BALL`
  //   `FLOAT_VIEW` = user_grant + **system_basic** ⇒ 普通签名证书没有对应 ACL，
  //   在 AGC 申请受限权限通过前**不能写进 module.json5**（否则装机失败 9568289）。
  //
  // 所以这里全程抛错：没权限就由 `openCastWindow` 降级到应用子窗口。
  // 权限批下来后，只需在 module.json5 加一条 requestPermissions，本路径自动生效。

  /** 打开系统级悬浮窗（需要 FLOAT_VIEW；失败即抛错，由上层降级） */
  private async openFloatWindow(): Promise<void> {
    if (!floatView.isFloatViewEnabled()) {
      throw new Error('本设备不支持应用悬浮窗（isFloatViewEnabled=false）');
    }
    const d: display.Display = display.getDefaultDisplaySync();
    const shortSide: number = Math.min(d.width, d.height);
    const w: number = Math.round(shortSide * 0.9);
    const h: number = Math.round(w * 9 / 16);

    const cfg: floatView.FloatViewConfiguration = {
      context: getContext(this),
      templateType: floatView.FloatViewTemplateType.ROUNDED_RECTANGLE,
      isConfirmOnClose: false
    };
    const ctl: floatView.FloatViewController = await floatView.create(cfg);

    // ① 挂载地图页
    await ctl.setUIContext('pages/CastWindow');

    // ② 尺寸做成 16:9，与车机 1280×720 同比例
    try {
      const size: window.Size = { width: w, height: h };
      await ctl.setWindowSize(size);
    } catch (e) {
      CarLifeRuntime.addLog('[悬浮窗] 尺寸设置失败（用系统默认）');
    }

    // ③ 启动 —— 这一步需要 FLOAT_VIEW，没权限会抛 201
    await ctl.start();
    this.floatCtl = ctl;

    // ④ 拿实际窗口矩形 → 区域采集；并监听拖动/缩放
    const props: floatView.FloatViewProperties = ctl.getWindowProperties();
    const r: window.Rect = props.windowRect;
    this.regionOnly = true;
    this.regionText = `系统悬浮窗 ${Math.round(r.width)}x${Math.round(r.height)}`
      + ` @(${Math.round(r.left)},${Math.round(r.top)})`;
    const src = this.castSrc;
    if (src !== null) {
      src.setCaptureArea(r.left, r.top, r.width, r.height);
    }
    try {
      ctl.onRectChange((info: floatView.FloatViewRectChangeInfo) => {
        const rr: window.Rect = info.windowRect;
        const s2 = this.castSrc;
        if (s2 !== null) {
          s2.setCaptureArea(rr.left, rr.top, rr.width, rr.height);
        }
      });
    } catch (e) {
      CarLifeRuntime.addLog('[悬浮窗] 矩形变化监听注册失败');
    }
    CarLifeRuntime.addLog(`[悬浮窗] ★ 已启动 ${this.regionText}`);
  }

  /** 打开独立投屏窗口（16:9 横屏，加载地图页），并把采集区域锁到它 */
  private async openCastWindow(): Promise<void> {
    if (this.castWin !== null || this.floatCtl !== null) {
      this.regionText = '投屏窗口已打开';
      return;
    }

    // ① 优先系统级悬浮窗：能浮在其他 App 之上，手机可同时用别的 App。
    //    没权限（FLOAT_VIEW 未在 AGC 申请到 ACL）时 start() 抛 201，自动降级。
    try {
      await this.openFloatWindow();
      this.castWinOpen = true;
      return;
    } catch (e) {
      const ferr = e as Error;
      CarLifeRuntime.addLog(`[投屏窗口] 悬浮窗不可用：${ferr.message} → 降级为应用子窗口`);
    }

    // ② 降级：应用子窗口（不需要任何权限，但切到别的 App 时不可见）
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const d: display.Display = display.getDefaultDisplaySync();
      const shortSide: number = Math.min(d.width, d.height);
      const w: number = Math.round(shortSide * 0.9);
      const h: number = Math.round(w * 9 / 16);
      const rect: window.Rect = {
        left: 0,
        top: Math.round(shortSide * 0.1),
        width: w,
        height: h
      };

      const options: window.SubWindowOptions = {
        title: '投屏画面',
        decorEnabled: false,
        windowRect: rect
      };
      const sub: window.Window =
        await ctx.windowStage.createSubWindowWithOptions('carhi_cast', options);
      this.castWin = sub;

      await sub.loadContent('pages/CastWindow');
      try {
        await sub.setPreferredOrientation(window.Orientation.LANDSCAPE);
      } catch (e) {
        CarLifeRuntime.addLog('[投屏窗口] 方向设置失败（忽略）');
      }

      this.regionOnly = true;
      this.castWinOpen = true;
      this.regionText = `独立投屏窗口 ${w}x${h}（16:9）`;
      CarLifeRuntime.addLog(`[投屏窗口] 已打开 ${w}x${h} @(${rect.left},${rect.top})`);

      // 采集区域 = 子窗口矩形
      const src = this.castSrc;
      if (src !== null) {
        src.setCaptureArea(rect.left, rect.top, rect.width, rect.height);
      }
    } catch (e) {
      const err = e as Error;
      this.regionText = `投屏窗口打开失败：${err.message}`;
      CarLifeRuntime.addLog(`[投屏窗口] ✗ ${this.regionText}`);
      this.castWin = null;
      this.castWinOpen = false;
    }
  }

  /** 关闭独立投屏窗口并恢复整屏采集 */
  private async closeCastWindow(): Promise<void> {
    // 系统悬浮窗优先关（它可能正在生效）
    const ctl = this.floatCtl;
    this.floatCtl = null;
    if (ctl !== null) {
      try {
        await ctl.stop();
        CarLifeRuntime.addLog('[悬浮窗] 已停止');
      } catch (e) {
        const err = e as Error;
        CarLifeRuntime.addLog(`[悬浮窗] 停止失败：${err.message}`);
      }
    }

    const w = this.castWin;
    this.castWin = null;
    this.castWinOpen = false;
    if (w !== null) {
      try {
        await w.destroyWindow();
        CarLifeRuntime.addLog('[投屏窗口] 已关闭');
      } catch (e) {
        const err = e as Error;
        CarLifeRuntime.addLog(`[投屏窗口] 关闭失败：${err.message}`);
      }
    }
    this.regionOnly = false;
    const src = this.castSrc;
    if (src !== null) {
      src.clearCaptureArea();
    }
    this.regionText = '';
  }

  /** 开关独立投屏窗口 */
  private toggleCastWindow(): void {
    if (this.castWin !== null) {
      this.closeCastWindow();
    } else {
      this.openCastWindow();
    }
  }

  /**
   * 监听窗口状态/尺寸/位置变化。
   *
   * ★ 2026-10-18 起**无条件注册**（`aboutToAppear` 里调用），因为「系统窗口管理」
   * 这条路径完全由系统手势触发 —— 用户把应用拖成悬浮小窗的那一刻，
   * 只有 `windowStatusChange` 能通知到我们。
   */
  private startRegionWatch(): void {
    if (this.regionWin !== null) {
      return;
    }
    window.getLastWindow(getContext(this)).then((win: window.Window) => {
      this.regionWin = win;
      // 启动时同步一次当前状态：可能应用是**以悬浮窗身份被拉起**的
      // （例如从小窗状态切到别的 App 再切回来），此时不会再触发 statusChange。
      try {
        const st: window.WindowStatusType = win.getWindowStatus();
        if (st === window.WindowStatusType.FLOATING && !this.floatMode) {
          CarLifeRuntime.addLog('[小窗] 启动即为悬浮窗 → 直接接管');
          this.floatMode = true;
          this.enterFloatMode();
        }
      } catch (e) {
        // 状态查询失败不影响后续监听
      }
      try {
        win.on('windowSizeChange', (size: window.Size) => {
          if (this.regionOnly || this.floatMode) {
            this.applyRegionFromWindow();
          }
        });
      } catch (e) {
        CarLifeRuntime.addLog('[小窗] windowSizeChange 监听注册失败');
      }
      try {
        win.on('windowRectChange', (data: window.RectChangeOptions) => {
          if (this.regionOnly || this.floatMode) {
            this.applyRegionFromWindow();
          }
        });
      } catch (e) {
        CarLifeRuntime.addLog('[小窗] windowRectChange 监听注册失败');
      }
      try {
        // ★★ 核心：系统把本应用拖成悬浮小窗 / 拖回全屏时自动接管
        win.on('windowStatusChange', (status: window.WindowStatusType) => {
          const isFloat: boolean = status === window.WindowStatusType.FLOATING;
          CarLifeRuntime.addLog(`[小窗] 窗口状态 → ${status}（悬浮=${isFloat}）`);
          if (isFloat === this.floatMode) {
            return;
          }
          this.floatMode = isFloat;
          if (isFloat) {
            this.enterFloatMode();
          } else {
            this.exitFloatMode();
          }
        });
      } catch (e) {
        CarLifeRuntime.addLog('[小窗] windowStatusChange 监听注册失败');
      }
      this.regionWatching = true;
      CarLifeRuntime.addLog('[小窗] 窗口变化监听已注册');
    }).catch((e: Error) => {
      CarLifeRuntime.addLog(`[小窗] 取窗口失败：${e.message}`);
    });
  }

  /** 注销窗口监听 */
  private stopRegionWatch(): void {
    const win = this.regionWin;
    if (win === null) {
      return;
    }
    try {
      win.off('windowSizeChange');
      win.off('windowRectChange');
      win.off('windowStatusChange');
    } catch (e) {
      // 注销失败不影响功能
    }
    this.regionWatching = false;
    this.regionWin = null;
  }

  // ================= ★★ 系统小窗（悬浮窗）自动接管 =================
  //
  // 这条路径的前提是 module.json5 里声明了 `supportWindowMode: [..., "floating"]`，
  // 否则系统根本不会把本应用当成"可以拖成小窗"的应用。
  //
  // 用户拖成小窗的那一刻：
  //   ① 界面切成**纯地图 16:9**（`floatMode` 分支），否则车机看到的是设置列表
  //   ② `setPreferredOrientation(LANDSCAPE)` + `resize(16:9)`（resize 只在 FLOATING 下生效）
  //   ③ 采集区域锁到该窗口矩形，车机只看到这块
  // 拖回全屏时全部还原。

  /** 进入系统小窗模式 */
  private async enterFloatMode(): Promise<void> {
    CarLifeRuntime.addLog('[小窗] ★ 已进入悬浮窗：切 16:9 横屏 + 锁采集区域');
    this.regionOnly = true;
    await this.applySmallWindowLandscape();
    // 系统切换瞬间的 windowRect 可能还没稳定，稍后再取一次纠偏。
    // 不用 await：这只是补一次，`windowRectChange` 才是常态跟随。
    setTimeout(() => {
      if (this.floatMode) {
        this.applyRegionFromWindow();
      }
    }, 400);
  }

  /** 退出系统小窗模式（拖回全屏） */
  private async exitFloatMode(): Promise<void> {
    CarLifeRuntime.addLog('[小窗] 已退出悬浮窗：恢复竖屏 + 整屏采集');
    this.regionOnly = false;
    await this.restorePortrait();
    // 独立投屏子窗口还开着时不撤区域 —— 那是另一条路径，区域由它自己管
    if (!this.castWinOpen) {
      const src = this.castSrc;
      if (src !== null) {
        src.clearCaptureArea();
      }
      this.regionText = '';
    }
  }

  /** 开关「小窗投屏」（手动开关；系统拖拽路径不需要它） */
  private toggleRegionOnly(): void {
    this.regionOnly = !this.regionOnly;
    if (this.regionOnly) {
      this.startRegionWatch();
      // 此刻若已是悬浮小窗 → 直接切横屏 + 16:9；否则只提示，
      // 等用户拖成小窗后由 windowStatusChange 自动接管
      this.applySmallWindowLandscape();
      CarLifeRuntime.addLog('[小窗投屏] 已开启：只投本应用窗口区域');
    } else {
      this.stopRegionWatch();
      this.restorePortrait();
      const src = this.castSrc;
      if (src !== null) {
        src.clearCaptureArea();
      }
      this.regionText = '';
      CarLifeRuntime.addLog('[小窗投屏] 已关闭：恢复整屏采集');
    }
  }

  // ================= ★ 采集存活看门狗（2026-10-15） =================
  //
  // 为什么需要它：`startCapture` 返回 0 只代表"管线建起来了"，
  // **不代表后面会持续出帧**。之前的调试里多次出现"启动成功但车机画面卡住"，
  // 而设置页只显示一条静态文案，无法区分「在出帧」和「早断了」。
  //
  // 这个看门狗每秒读一次 native 侧真实计数，算 fps 和"距上次出帧多久"：
  //   - fps 归零 + lastOut 持续增长  → **确定断流**（UI 直接标红）
  //   - frames 不增但 lastOut 很小   → 正常（静态画面也可能降到低帧率）
  //
  // ⚠ 已知局限（不要误判）：ArkUI 的定时器在**应用切后台/息屏时可能被冻结**，
  //   此时面板数值会停更 —— 停更 ≠ 断流。车机上的画面才是最终判据。

  /** 出帧打点（两条采集路径共用） */
  private onCastFrame(nalu: Uint8Array, pts: number, keyFrame: boolean): void {
    this.castFramesRaw++;
    this.castLastFrameAt = Date.now();
  }

  /** 启动诊断轮询 */
  private startCastWatchdog(): void {
    this.stopCastWatchdog();
    this.castFramesRaw = 0;
    this.castFramesPrev = 0;
    this.castLastFrameAt = 0;
    this.castTickAt = Date.now();
    this.castFrames = 0;
    this.castFps = 0;
    this.castLastOutMs = -1;
    this.castWatchdogText = '诊断启动中…';

    this.castTimerId = setInterval(() => {
      const now: number = Date.now();

      // ① 帧计数：native 真值（含推流路径），取两者较大值防口径不一致
      let frames: number = this.castFramesRaw;
      try {
        const sz = carlifecodec.captureEncodedSize();
        if (sz !== undefined && sz !== null && sz.width > 0) {
          this.castSize = `${sz.width}x${sz.height}`;
        }
      } catch (e) {
        // native 未就绪：忽略，尺寸保持上一次
      }
      const src = this.castSrc;
      if (src !== null) {
        const d = src.diag();
        if (d.frames > frames) {
          frames = d.frames;
        }
      }

      // ② 实测 fps（本轮增量 / 间隔）
      const dtSec: number = Math.max(0.2, (now - this.castTickAt) / 1000);
      const delta: number = frames - this.castFramesPrev;
      this.castFps = delta > 0 ? Math.round((delta / dtSec) * 10) / 10 : 0;
      this.castFramesPrev = frames;
      this.castTickAt = now;
      this.castFrames = frames;

      // ③ 距上次出帧（打点优先；没有打点则用 native 帧数变化兜底）
      if (this.castLastFrameAt > 0) {
        this.castLastOutMs = now - this.castLastFrameAt;
      } else if (frames > 0) {
        this.castLastOutMs = this.castLastOutMs < 0 ? 0 : this.castLastOutMs + Math.round(dtSec * 1000);
      }

      // ④ 结论文案
      if (frames === 0) {
        this.castWatchdogText = '⚠ 尚未产出任何帧（可能还在等授权 / 编码器未就绪）';
      } else if (this.castLastOutMs >= 0 && this.castLastOutMs > 3000) {
        this.castWatchdogText = `⚠ 已 ${(this.castLastOutMs / 1000).toFixed(1)} 秒无新帧 —— 采集疑似断流`;
      } else {
        this.castWatchdogText = `✔ 正在出帧（累计 ${frames}，${this.castFps} fps）`;
      }
    }, 1000);
  }

  /** 停掉诊断轮询 */
  private stopCastWatchdog(): void {
    if (this.castTimerId !== -1) {
      clearInterval(this.castTimerId);
      this.castTimerId = -1;
    }
    this.castWatchdogText = '未开启';
    this.castLastOutMs = -1;
    this.castFps = 0;
  }

  /** 诊断行（标签 + 值 + 颜色） */
  @Builder
  DiagLine(label: string, value: string, color: string) {
    Row() {
      Text(label).fontSize(10).fontColor('#6E7681').width(72)
      Text(value).fontSize(10).fontColor(color).layoutWeight(1)
    }
    .width('100%')
  }

  private stopAppCast(): void {
    this.stopCastWatchdog();
    // 独立投屏窗口随采集一起关掉（否则窗口还在但画面不更新，看着像卡死）
    if (this.castWin !== null) {
      this.closeCastWindow();
    }
    // 小窗投屏：停采集时撤掉窗口监听，但**保留开关状态**（下次投屏自动恢复区域）
    this.stopRegionWatch();
    if (this.castSrc !== null) {
      this.castSrc.stop();
    }
    this.castRunning = false;
    this.castText = '已停止';
    this.castFrames = this.castFramesRaw;

    // 切回自绘源
    EngineHolder.setForceCaptureSource(null);
    const engine = EngineHolder.engine;
    if (engine !== null) {
      engine.switchFrameSource();
    }
    CarLifeRuntime.addLog('[投屏] 已停止采集，画面源切回自绘');
    AppStorage.setOrCreate<boolean>('carhiFloatOn', false);
  }

  /** 打开高德 MapView 真地图（道路底图在手机本机原生渲染）。 */
  private openRealMapPage(): void {
    if (this.showAmapNavi) {
      this.closeAmapNaviPage();
    }
    this.realMapStartedCast = false;
    this.showRealMap = true;
    CarLifeRuntime.addLog('[真地图] MapView 页面已打开；车机显示需在地图页显式点「投屏到车机」');
  }

  /** 地图页内显式启停整屏投屏；屏幕采集授权仍由系统弹窗确认。 */
  private toggleRealMapCast(): void {
    if (this.castRunning) {
      this.stopAppCast();
      this.realMapStartedCast = false;
      return;
    }
    this.startAppCast();
    this.realMapStartedCast = this.castRunning;
  }

  /** 退出地图时，只关闭由地图页自己开启的投屏。 */
  private closeRealMapPage(): void {
    if (this.realMapStartedCast && this.castRunning) {
      this.stopAppCast();
    }
    this.realMapStartedCast = false;
    this.showRealMap = false;
    CarLifeRuntime.addLog('[真地图] MapView 页面已关闭');
  }

  /**
   * ★ A3′：打开高德原生导航页，并把**画面源切到「页面喂图」**。
   *
   * 为什么必须切画面源：出帧有两条互斥的路（共享同一个编码器 surface）——
   *   1. native 自绘（`HmiRenderer` 画我们的 CarWith 版式卡片）
   *   2. 页面喂图（截图 → `PushPixels`）
   * 高德 `AMapNaviComponent` 的画面是它自己在 ArkUI 里渲染的，
   * **只能走第 2 条**（我们拿不到它的 surface）。
   *
   * 所以要停自绘、切截图，再启动截图循环。
   */
  private openAmapNaviPage(): void {
    CarLifeRuntime.addLog('[高德导航页] 打开（北京西站 → 天安门，模拟）');
    this.showAmapNavi = true;

    const src = EngineHolder.frameSource;
    if (src !== null && src.isRunning) {
      const ok: boolean = src.enterPageSourceMode();
      if (ok) {
        // ★ 画面由**高德引擎截图**提供（AmapNaviPage 内部循环 → onFrame 回调），
        //   不再启动组件截图循环 —— 后者开销大且高频不稳（实测 3 帧就停）。
        this.amapFrameLogged = false;
        this.amapFrameErrLogged = false;
        CarLifeRuntime.addLog('[高德导航页] 已切画面源，等引擎截图首帧…');
      } else {
        CarLifeRuntime.addLog('[高德导航页] ⚠ 画面源切换失败，车机可能仍显示自绘画面');
      }
    } else {
      CarLifeRuntime.addLog('[高德导航页] 推流管线未启动，仅手机本地显示');
    }
  }

  /** 关闭高德导航页，画面源切回 native 自绘 */
  private closeAmapNaviPage(): void {
    this.showAmapNavi = false;
    this.stopFallbackPush();

    const src = EngineHolder.frameSource;
    if (src !== null && src.isRunning) {
      src.exitPageSourceMode(() => {
        this.syncFromAmap();
        this.syncHmi();
      });
    }
    CarLifeRuntime.addLog('[高德导航页] 已关闭，画面源切回自绘');
  }

  /**
   * 从**高德真实导航数据**同步到 HMI 状态。
   *
   * 这是「复用高德导航能力」的核心落点：把 `AmapNaviSnapshot` 的字段
   * 填进渲染器要的 `navi.*`，车机画面就从「占位数据」变成「真实导航」。
   *
   * ★ 只在真的在导航时才覆盖 —— 否则会把占位演示数据也冲掉，
   *   车机首页看不到东西（没导航时保持原样更好）。
   */
  private syncFromAmap(): void {
    const bridge = NaviInfoProbe.bridgeInstance();
    if (bridge === null || !bridge.ready) {
      return;
    }
    const snap = bridge.snapshot();
    if (!snap.navigating) {
      return;
    }

    // ---- 转向 + 距离 ----
    const turn: number = mapAmapIconToTurnType(snap.iconType);
    if (this.navTurnType !== turn) {
      this.navTurnType = turn;
    }
    // 距离展示：<1km 用米，否则用公里（保留一位小数）
    const distText: string = snap.segRemainDis >= 1000
      ? (snap.segRemainDis / 1000).toFixed(1)
      : `${Math.round(snap.segRemainDis)}`;
    const distUnit: string = snap.segRemainDis >= 1000 ? 'km' : 'm';
    if (this.navDistance !== distText) {
      this.navDistance = distText;
    }
    if (this.navUnit !== distUnit) {
      this.navUnit = distUnit;
    }

    // ---- 路名 ----
    const road: string = snap.road.length > 0 ? snap.road : '当前道路';
    if (this.navRoad !== road) {
      this.navRoad = road;
    }
    // 主提示 = 转向动作 + 路名（渲染器导航卡的主标题会自动拼「前方 xxx 动作」）
    const hint: string = `${turnTypeActionText(turn)}进入${snap.nextRoad.length > 0 ? snap.nextRoad : road}`;
    if (this.navHint !== hint) {
      this.navHint = hint;
    }
    // 下一步 = 红绿灯数量（我们独有的信息，CarWith 没有）
    const next: string = snap.remainLightCount > 0
      ? `前方 ${snap.remainLightCount} 个红绿灯`
      : '继续沿当前道路行驶';
    if (this.navNext !== next) {
      this.navNext = next;
    }

    // ---- 剩余里程/时间（放到通勤卡上，复用现成字段）----
    const etaMin: number = Math.round(snap.routeRemainTime / 60);
    if (etaMin > 0 && this.etaMinutes !== etaMin) {
      this.etaMinutes = etaMin;
    }
  }

  private syncHmi(): void {
    // ★ 诊断：确认推给渲染器的真实值（仅在高德导航时打，避免刷屏）
    const b = NaviInfoProbe.bridgeInstance();
    if (b !== null && b.ready && b.snapshot().navigating) {
      const s = b.snapshot();
      // 每秒最多一条（这里用 300ms 轮询里做粗过滤：只有整秒才打）
      const nowSec: number = Math.floor(Date.now() / 1000);
      if (nowSec !== this.lastHmiLogSec) {
        this.lastHmiLogSec = nowSec;
        CarLifeRuntime.addLog(`[HMI→车机] 转向=${this.navTurnType}`
          + ` 距离=${this.navDistance}${this.navUnit} 路=${this.navRoad}`
          + ` 红绿灯=${s.remainLightCount}`);
      }
    }
    EngineHolder.pushHmi({
      page: this.page === 1 ? HMI_PAGE_NAVI : HMI_PAGE_HOME,
      connected: this.running ? 1 : 0,
      navi: {
        turnType: this.navTurnType,
        distanceM: 300,
        progress: this.navProgress,
        distanceText: this.navDistance,
        distanceUnit: this.navUnit,
        road: this.navRoad,
        hint: this.navHint,
        nextHint: this.navNext
      },
      audio: {
        title: this.trackName,
        artist: this.trackArtist,
        positionMs: this.progressSec * 1000,
        durationMs: this.durationSec * 1000,
        playing: this.playing ? 1 : 0
      },
      status: {
        clock: this.statusClock,
        signalBars: this.statusSignalBars,
        carrier: this.statusCarrier,
        batteryPct: this.statusBattery
      },
      weather: {
        tempC: this.weatherTemp,
        condition: this.weatherCondition,
        city: this.weatherCity,
        airQuality: this.weatherAir
      },
      eta: {
        minutes: this.etaMinutes,
        arriveAt: this.etaArriveAt
      }
    });
  }

  /**
   * 同步 native 自绘诊断到 @State（设置页展示）。
   *
   * native 侧的数据是静态字段，没有变更通知，只能轮询；300ms 一次、只在
   * 值变化时赋值，避免空刷新。
   */
  private syncHmiDiag(): void {
    const src = EngineHolder.frameSource;
    if (src === null) {
      if (this.hmiDiagText !== '未运行') {
        this.hmiDiagText = '未运行';
      }
      if (this.hmiBackend !== -1) {
        this.hmiBackend = -1;
      }
      if (this.hmiFallback) {
        this.hmiFallback = false;
      }
      if (this.hmiSelfTest) {
        this.hmiSelfTest = false;
      }
      return;
    }
    const d: HmiDiag = src.diag();
    const text: string = src.stats();
    if (this.hmiDiagText !== text) {
      this.hmiDiagText = text;
    }
    if (this.hmiBackend !== d.backend) {
      this.hmiBackend = d.backend;
    }
    if (this.hmiFallback !== d.fallback) {
      this.hmiFallback = d.fallback;
    }
    if (this.hmiSelfTest !== src.isSelfTest) {
      this.hmiSelfTest = src.isSelfTest;
    }
  }

  // ==================== 兜底：截图推流 ====================

  /** 兜底模式是否需要启动截图循环 */
  private ensureFallbackPush(): void {
    const src = EngineHolder.frameSource;
    if (src !== null && src.isRunning && src.isFallback) {
      this.startFallbackPush();
    } else if (this.fallbackTimer !== -1) {
      this.stopFallbackPush();
    }
  }

  /**
   * 启动「截图 → pushFrame」兜底推流。
   *
   * 这是 2026-10-14 前台验证过的那条路（编码器 + PushPixels，出过 300 帧）。
   * 只在 native 自绘起不来时才走，代价是**切后台会冻结**（系统停 ArkUI 渲染）。
   * 频率 50ms（20fps）—— 截图本身 ~26ms，再快也只是把 CPU 打满。
   */
  private startFallbackPush(): void {
    if (this.fallbackTimer !== -1) {
      return;
    }
    const ctx = this.getUIContext();
    this.fallbackTimer = setInterval(() => {
      if (this.fallbackBusy) {
        return;
      }
      const src = EngineHolder.frameSource;
      if (src === null || !src.isRunning || !src.isFallback) {
        // ★ 诊断：只在导航页打开时打一次，说明为什么没喂图
        if (this.showAmapNavi && !this.fallbackMaskLogged) {
          this.fallbackMaskLogged = true;
          CarLifeRuntime.addLog(`[兜底] 跳过截图：src=${src === null ? 'null' : 'ok'}`
            + ` running=${src !== null ? src.isRunning : false}`
            + ` isFallback=${src !== null ? src.isFallback : false}`);
        }
        return;
      }
      this.fallbackBusy = true;
      try {
        // ★ 截图目标：导航页打开时截高德页自己的容器，否则截整页 hmi_root。
        //   为什么要分开：高德 `AMapNaviComponent` 是独立渲染的组件，
        //   截外层 hmi_root 在部分机型上会拿不到它的内容（或拿到空白）。
        const target: string = this.showAmapNavi ? 'amap_navi_root' : 'hmi_root';
        const pm = ctx.getComponentSnapshot().getSync(target);
        const info = pm.getImageInfoSync();
        const w: number = info.size.width;
        const h: number = info.size.height;
        const bytes: number = pm.getPixelBytesNumber();
        // pushFrame 要求 RGBA8888（len >= w*h*4）。截图若换了像素格式，
        // 这里会显式报出来，而不是每帧静默失败。
        if (bytes < w * h * 4) {
          CarLifeRuntime.addLog(`[兜底] ✗ 截图不是 RGBA8888（${w}x${h}, ${bytes} 字节），停`);
          pm.release();
          this.stopFallbackPush();
          return;
        }
        if (this.fallbackBuf === null || this.fallbackBuf.byteLength !== bytes) {
          this.fallbackBuf = new ArrayBuffer(bytes);
        }
        pm.readPixelsToBufferSync(this.fallbackBuf);
        src.feedScreenshot(this.fallbackBuf, w, h);
        pm.release();
        if (!this.fallbackLogged) {
          this.fallbackLogged = true;
          CarLifeRuntime.addLog(`[兜底] 首帧已推：截图 ${w}x${h}（编码 ${src.canvasWidth}x`
            + `${src.canvasHeight}，按居中裁剪拉伸适配）`);
        }
      } catch (e) {
        const err = e as Error;
        CarLifeRuntime.addLog(`[兜底] 截图推流失败，已停: ${err.message}`);
        this.stopFallbackPush();
      } finally {
        this.fallbackBusy = false;
      }
    }, 50);
    this.fallbackMaskLogged = false;
    CarLifeRuntime.addLog('[兜底] 截图推流已启动（20fps，仅前台有效）');
  }

  private stopFallbackPush(): void {
    if (this.fallbackTimer === -1) {
      return;
    }
    clearInterval(this.fallbackTimer);
    this.fallbackTimer = -1;
    this.fallbackBusy = false;
    this.fallbackBuf = null;
    this.fallbackLogged = false;
  }

  /** 手动切换渲染后端（设置页按钮） */
  private switchHmiBackend(backend: number): void {
    const src = EngineHolder.frameSource;
    if (src === null || !src.isRunning) {
      CarLifeRuntime.addLog('[自绘] 画面通路未运行，无法切换后端');
      return;
    }
    if (src.isFallback) {
      CarLifeRuntime.addLog('[自绘] 当前是截图推流兜底模式，后端切换无效');
      return;
    }
    this.hmiBackendReq = backend;
    src.setBackend(backend);
  }

  /**
   * 自绘自测（**不需要车机**）。
   *
   * 画面管线平时只在车机下发 98313 后才启动，所以车机不在手边时设置页永远
   * 显示「未运行」，什么都验证不了。这个入口直接把「编码器 + 自绘渲染」跑起来，
   * 用上面那几个诊断数字判断成败：
   *   - 「帧 N」在涨 → 渲染线程在出帧
   *   - 「编码器出帧 M」在涨 → 像素真的进了编码器（这是 A2 当年失败的地方）
   *   - 出现「★已自愈」→ GPU 后端不通，已自动退 CPU
   */
  private toggleSelfTest(): void {
    const src = EngineHolder.ensureFrameSource();
    if (src.isRunning && src.isSelfTest) {
      src.stop();
      this.syncHmiDiag();
      this.statusMessage = '自测已停止，点「启动服务」恢复监听';
      return;
    }
    if (src.isRunning) {
      CarLifeRuntime.addLog('[自测] 画面通路已被占用（推流/兜底中），先停止再自测');
      return;
    }
    if (this.running) {
      CarLifeRuntime.addLog('[自测] 先停掉监听服务，避免与车机推流抢编码器');
      this.stopService();
    }
    const ok: boolean = src.startSelfTest(1280, 720, 30);
    // 推一次当前状态，让自绘画面不是空壳
    this.syncHmi();
    this.syncHmiDiag();
    if (ok) {
      this.statusMessage = '自测中（监听服务已暂停，停止自测后点「启动服务」恢复）';
    }
  }

  /**
   * 离线自检：**绕过编码器**，只验渲染器。
   *
   * ## 为什么单列一个按钮
   *
   * 2026-10-14 在模拟器上定到硬结论：**这台模拟器没有任何视频编码器**
   * （AVC/HEVC 全不可用），于是上面那个「自绘自测」在 stage=1 就退出了，
   * 一个数字都显示不出来。而「画得出来吗」只依赖 Skia，跟编码器无关 ——
   * 所以单拎一条不碰编码器的路。
   *
   * 它同步画首页 + 导航页各一遍，返回每页耗时，并把画面落成 PNG 到沙箱
   * （`files/hmi_home.png` / `files/hmi_navi.png`），可以拉回宿主机肉眼比对。
   *
   * ⚠ 同步阻塞，所以先置忙、跑完再放开，避免连点。
   */
  private runOfflineSelfCheck(): void {
    if (this.hmiCheckBusy) {
      return;
    }
    this.hmiCheckBusy = true;
    this.hmiCheckText = '自检中…';
    CarLifeRuntime.addLog('[自检] 开始离线渲染自检（不碰编码器）');
    runHmiSelfCheck(1280, 720).then((out: HmiSelfCheckOutcome) => {
      this.hmiCheckBusy = false;
      let text: string = out.text;
      if (out.homePath.length > 0 || out.navPath.length > 0) {
        text += `｜${out.homePath.length > 0 ? 'home.png' : ''}`
          + `${out.navPath.length > 0 ? ' navi.png' : ''}`;
      }
      this.hmiCheckText = (out.ok ? '✓ ' : '✗ ') + text;
    }).catch((e: Error) => {
      this.hmiCheckBusy = false;
      this.hmiCheckText = `✗ 自检异常：${e.message}`;
      CarLifeRuntime.addLog(`[自检] ✗ 异常 ${e.message}`);
    });
  }
}
