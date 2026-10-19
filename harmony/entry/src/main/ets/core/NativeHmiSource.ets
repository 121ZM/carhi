/**
 * 原生自绘 HMI 画面来源（路线 A1）
 *
 * ## 角色
 *
 * 把「车机桌面」这件事从 ArkUI 手里拿走，交给 native 自己的渲染线程：
 *
 *   ArkTS（只推状态：页面 / 导航 / 音频）
 *        │ setHmiState()
 *        ▼
 *   HmiRenderer（native，OH_Drawing/Skia 画到编码器输入 surface）
 *        │ 自有渲染线程，与屏幕显示状态无关
 *        ▼
 *   OH_VideoEncoder ──▶ H.264 裸流 ──▶ CarLifeEngine ──▶ 车机 8240
 *
 * ## 为什么必须这样（2026-10-14 实测结论）
 *
 * 旧路子是「ArkUI 画界面 → getSync 截图 → 拷进编码器」：
 *   - 截图 ~26ms/帧，**切后台后系统停止渲染** → 后台画面冻结，而后台推流是刚需；
 *   - 每帧一次 14MB RGBA 拷贝；
 *   - 离屏快照 createFromBuilder 实测 345ms/帧（≈2fps），已判死。
 *
 * 换成 native 自绘后：绘制权在我们自己手里，渲染循环是**应用自己的线程**，
 * 系统不再参与 —— 这就是「切后台不掉」的根据。
 *
 * ## 三层保命（2026-10-14 晚加入）
 *
 * native 自绘这条路**还没在真机验证过**，所以不能只有一条命：
 *   1. GPU OnScreen 后端（首选，零拷贝）
 *   2. GPU 提交了帧但编码器不出帧 → native 侧**自愈**退 CPU 位图后端
 *   3. 连渲染器都起不来（stage 8/9）→ 本类**回落**到「截图推流」
 *      （编码器 + PushPixels，这条 GL 上传通路已实测出过帧）
 * 外加设置页一个**手动切后端**开关，黑屏时用户自己就能救。
 *
 * ## 与 CanvasFrameSource 的关系
 *
 * 两者都实现 FrameSource，但取画面的方式完全不同：
 *   - CanvasFrameSource：外部 surfaceId（XComponent）→ 截图 → pushFrame
 *   - NativeHmiSource ：**不需要 surfaceId**，native 用编码器自己的输入 surface
 * 后者已取代前者作为默认画面来源；前者保留作诊断兜底。
 */

import { FrameSource } from './CarLifeEngine';
import { VideoParams } from './StateMachine';
import { CarLifeRuntime } from '../entryability/EntryAbility';
import carlifecodec from 'libcarlifecodec.so';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';

/** HMI 页面（与 native 的 HmiPage 对齐） */
export const HMI_PAGE_HOME: number = 0;
export const HMI_PAGE_NAVI: number = 1;

/** 转向类型（与 native 的 HmiTurnType 对齐） */
export const HMI_TURN_NONE: number = 0;
export const HMI_TURN_LEFT: number = 1;
export const HMI_TURN_RIGHT: number = 2;
export const HMI_TURN_STRAIGHT: number = 3;
export const HMI_TURN_ARRIVE: number = 4;

/** 渲染后端（与 native 的 HmiRenderer::Backend 对齐） */
export const HMI_BACKEND_AUTO: number = 0;
export const HMI_BACKEND_GPU: number = 1;
export const HMI_BACKEND_CPU: number = 2;

interface EncoderOptions {
  width: number;
  height: number;
  frameRate: number;
  bitrate: number;
  iFrameIntervalMs?: number;
}

/** 导航卡状态（供 UI 层构造整包状态用） */
export interface HmiNaviState {
  turnType: number;
  distanceM: number;
  /**
   * 当前导航段进度 0-100（CarWith 语义）。
   *
   * native 侧把它渲染成**整张导航卡的背景填充**（从左往右），
   * 这是 CarWith 导航卡最标志性的视觉特征。≤0 不画进度。
   */
  progress: number;
  distanceText: string;
  distanceUnit: string;
  road: string;
  hint: string;
  nextHint: string;
}

/** 音频迷你卡状态 */
export interface HmiAudioState {
  title: string;
  artist: string;
  positionMs: number;
  durationMs: number;
  playing: number;
}

/** 顶部状态栏（首页） */
export interface HmiStatusState {
  clock: string;
  signalBars: number;
  carrier: string;
  batteryPct: number;
}

/** 天气卡（首页） */
export interface HmiWeatherState {
  tempC: number;
  condition: string;
  city: string;
  airQuality: string;
}

/** 通勤/到达卡（首页） */
export interface HmiEtaState {
  minutes: number;
  arriveAt: string;
}

/** HMI 整包状态（与 native 的 setHmiState 参数一一对应） */
export interface HmiStatePayload {
  page: number;
  connected: number;
  navi: HmiNaviState;
  audio: HmiAudioState;
  status: HmiStatusState;
  weather: HmiWeatherState;
  eta: HmiEtaState;
}

/** 自绘运行诊断快照（给设置页展示用） */
export interface HmiDiag {
  /** 是否在跑 */
  running: boolean;
  /** 是否处于「截图推流」兜底模式 */
  fallback: boolean;
  /** 当前后端：0 = GPU OnScreen，1 = CPU 位图，-1 = 未知 */
  backend: number;
  /** 渲染器已提交帧数 */
  frames: number;
  /** 编码器累计输出帧数（真正进编码器的画面数） */
  outputFrames: number;
  /** 是否发生过自愈降级 */
  selfHealed: boolean;
  /** 最近一次提交结果，0 = 成功 */
  flushCode: number;
}

export class NativeHmiSource implements FrameSource {
  private running: boolean = false;
  private onFrameCb: ((nalu: Uint8Array, pts: number, keyFrame: boolean) => void) | null = null;
  /** 目标画布尺寸（路线 A1 下由我们自己定，不再迁就物理屏） */
  private width: number = 1280;
  private height: number = 720;
  /**
   * 兜底模式标记。
   *
   * true = 自绘起不来，已回落到「编码器 + pushFrame(截图)」。
   * 此时画面**必须由页面喂**（feedScreenshot），我们自己是产不出帧的。
   */
  private fallback: boolean = false;
  /** 是否处于自测模式（无车机，仅验证渲染 + 编码出帧） */
  private selfTest: boolean = false;
  /** ★ 最近一次启动用的帧率（画面源切换时要按原参数重建编码器） */
  private static lastFps: number = 30;
  /** ★ 保活音频累计收到的 PCM 帧数（诊断用） */
  private static audioFrames: number = 0;

  /** 当前 HMI 状态（ArkTS 侧是唯一真值源，每次变更整包推给 native） */
  private payload: HmiStatePayload = {
    page: HMI_PAGE_HOME,
    connected: 0,
    navi: {
      turnType: HMI_TURN_RIGHT,
      distanceM: 300,
      progress: 42,
      distanceText: '300',
      distanceUnit: 'm',
      road: '科技路',
      hint: '前方路口右转进入科技路',
      nextHint: '然后 直行 1.2 km'
    },
    audio: {
      title: '未选择曲目',
      artist: '媒体源待接入',
      positionMs: 84000,
      durationMs: 238000,
      playing: 0
    },
    status: {
      clock: '01:18',
      signalBars: 4,
      carrier: '5G',
      batteryPct: 78
    },
    weather: {
      tempC: 26,
      condition: '多云',
      city: '上海',
      airQuality: '空气优'
    },
    eta: {
      minutes: 28,
      arriveAt: '09:10'
    }
  };

  get isRunning(): boolean {
    return this.running;
  }

  /** 是否在「截图推流」兜底模式（页面据此启动截图循环） */
  get isFallback(): boolean {
    return this.fallback;
  }

  /**
   * ★ A3′：切换到「页面喂图」模式 —— 让高德原生导航页的画面能推给车机。
   *
   * ## 为什么需要它
   *
   * 出帧有两条互斥的路（共享同一个编码器 surface，不能同时跑）：
   *   1. **native 自绘**：`HmiRenderer` 直接画进编码器 surface（CarWith 版式卡片）
   *   2. **页面喂图**：页面截图 → `feedScreenshot()` → `PushPixels()` 上传纹理
   *
   * 高德 `AMapNaviComponent` 的画面是它自己在 ArkUI 里渲染的，
   * 我们拿不到它的 surface —— **只能走第 2 条**（截图导出）。
   *
   * 所以导航页打开时调本方法切到第 2 条，关闭时调 `exitPageSourceMode()`
   * 切回第 1 条。产出的画面不同（高德导航界面 vs 我们的卡片），
   * 但**推流链路（编码器/协议/端口）完全复用**。
   *
   * @returns 切换是否成功（失败时调用方应保持原模式）
   */
  enterPageSourceMode(): boolean {
    if (!this.running) {
      CarLifeRuntime.addLog('[画面源] 切换失败：管线未启动');
      return false;
    }
    if (this.fallback) {
      return true;   // 已经是页面喂图模式（native 自绘本来就起不来）
    }

    // 记录必要的参数，用于切回来时重建自绘
    // （stopHmi 会销毁编码器，所以要按原参数重新 startHmi）
    const w: number = this.width;
    const h: number = this.height;

    try {
      carlifecodec.stopHmi();
      const opts: EncoderOptions = {
        width: w,
        height: h,
        frameRate: NativeHmiSource.lastFps,
        bitrate: NativeHmiSource.bitrateFor(w, h, NativeHmiSource.lastFps),
        iFrameIntervalMs: 2000
      };
      const frameCb = (data: ArrayBuffer, pts: number, keyFrame: boolean): void => {
        const cb = this.onFrameCb;
        if (cb !== null) {
          cb(new Uint8Array(data), pts, keyFrame);
        }
      };
      const fstage: number = carlifecodec.startEncoder('0', opts, frameCb, () => {});
      if (fstage !== 0) {
        CarLifeRuntime.addLog(`[画面源] ✗ 切页面喂图失败 stage=${fstage}，尝试回到自绘`);
        // 尽力回到自绘，避免画面彻底断掉
        carlifecodec.startHmi(opts, frameCb, () => {});
        return false;
      }
      this.fallback = true;
      CarLifeRuntime.addLog('[画面源] ★ 已切到「页面喂图」—— 高德导航页画面将推给车机');
      return true;
    } catch (e) {
      const err = e as Error;
      CarLifeRuntime.addLog(`[画面源] 切换异常: ${err.message}`);
      return false;
    }
  }

  /**
   * 从「页面喂图」切回「native 自绘」（导航页关闭时调）。
   *
   * @param onRestart 自绘重启后需要重新推一次 HMI 状态（否则车机看到旧画面）
   */
  exitPageSourceMode(onRestart: () => void): boolean {
    if (!this.running || !this.fallback) {
      return true;
    }
    const w: number = this.width;
    const h: number = this.height;
    try {
      carlifecodec.stopEncoder();
      const opts: EncoderOptions = {
        width: w,
        height: h,
        frameRate: NativeHmiSource.lastFps,
        bitrate: NativeHmiSource.bitrateFor(w, h, NativeHmiSource.lastFps),
        iFrameIntervalMs: 2000
      };
      const frameCb = (data: ArrayBuffer, pts: number, keyFrame: boolean): void => {
        const cb = this.onFrameCb;
        if (cb !== null) {
          cb(new Uint8Array(data), pts, keyFrame);
        }
      };
      const stage: number = carlifecodec.startHmi(opts, frameCb, () => {});
      if (stage !== 0) {
        CarLifeRuntime.addLog(`[画面源] ✗ 切回自绘失败 stage=${stage}，退回页面喂图`);
        carlifecodec.startEncoder('0', opts, frameCb, () => {});
        return false;
      }
      this.fallback = false;
      // ★ 自绘刚起来是空白的，必须立刻推一次状态，否则车机看到黑屏
      onRestart();
      CarLifeRuntime.addLog('[画面源] ★ 已切回「native 自绘」');
      return true;
    } catch (e) {
      const err = e as Error;
      CarLifeRuntime.addLog(`[画面源] 切回异常: ${err.message}`);
      return false;
    }
  }

  get canvasWidth(): number {
    return this.width;
  }

  get canvasHeight(): number {
    return this.height;
  }

  start(params: VideoParams,
        onFrame: (nalu: Uint8Array, pts: number, keyFrame: boolean) => void,
        onError: (code: number, msg: string) => void): boolean {
    if (this.running) {
      return true;
    }
    this.onFrameCb = onFrame;
    this.fallback = false;

    // ★ 路线 A1：画布尺寸**由我们自己定**（车机侧会自行缩放显示），
    //   不再等于手机物理屏尺寸 —— 那正是旧录屏方案把车机搞崩的根因。
    //   默认 1280×720（16:9，老车机硬解最稳），偶数对齐。
    let w: number = params.width > 0 ? params.width : 1280;
    let h: number = params.height > 0 ? params.height : 720;
    w = w - (w % 2);
    h = h - (h % 2);
    if (w < 320 || h < 240) {
      w = 1280;
      h = 720;
    }
    this.width = w;
    this.height = h;

    NativeHmiSource.lastFps = params.frameRate > 0 ? params.frameRate : 30;
    const opts: EncoderOptions = {
      width: w,
      height: h,
      frameRate: NativeHmiSource.lastFps,
      bitrate: NativeHmiSource.bitrateFor(w, h, params.frameRate > 0 ? params.frameRate : 30),
      iFrameIntervalMs: 2000
    };

    const frameCb = (data: ArrayBuffer, pts: number, keyFrame: boolean): void => {
      const cb = this.onFrameCb;
      if (cb !== null) {
        cb(new Uint8Array(data), pts, keyFrame);
      }
    };
    const errCb = (code: number, msg: string): void => {
      onError(code, msg);
    };

    const stage: number = carlifecodec.startHmi(opts, frameCb, errCb);

    if (stage !== 0) {
      CarLifeRuntime.addLog(`[自绘] ✗ 启动失败 stage=${stage}`
        + (stage === 8 ? '（拿不到编码器输入 surface）' : '')
        + (stage === 9 ? '（渲染后端不可用）' : ''));
      // ---- 回落：截图推流（编码器 + PushPixels，已验证出帧的通路）----
      // 注意 StartHmi 失败路径内部已经把编码器收干净了，这里可以重新起。
      const fstage: number = carlifecodec.startEncoder('0', opts, frameCb, errCb);
      if (fstage === 0) {
        this.fallback = true;
        this.running = true;
        this.startKeepAliveAudio();
        CarLifeRuntime.addLog('[自绘] ⚠ 已回落：截图推流兜底（前台可用，切后台会冻结）');
        return true;
      }
      CarLifeRuntime.addLog(`[自绘] ✗ 兜底也失败 stage=${fstage}，画面通路不可用`);
      this.onFrameCb = null;
      return false;
    }

    this.running = true;
    this.startKeepAliveAudio();
    // 立刻推一次初始状态，避免车机看到空画面
    carlifecodec.setHmiState(this.payload);
    CarLifeRuntime.addLog(`[自绘] 原生 HMI 已启动（${w}x${h} @ ${opts.frameRate}fps, `
      + `${Math.round(opts.bitrate / 1000)}kbps）`);
    return true;
  }

  stop(): void {
    if (!this.running) {
      return;
    }
    this.running = false;
    this.onFrameCb = null;
    this.selfTest = false;
    const wasFallback: boolean = this.fallback;
    this.fallback = false;
    try {
      carlifecodec.stopAudioCapture();
    } catch (e) {
      // ignore
    }
    try {
      if (wasFallback) {
        carlifecodec.stopEncoder();
      } else {
        carlifecodec.stopHmi();
      }
      CarLifeRuntime.addLog('[自绘] 画面通路已停止');
    } catch (e) {
      const err = e as Error;
      CarLifeRuntime.addLog(`[自绘] 停止异常: ${err.message}`);
    }
  }

  /**
   * 启动后台保活音频采集。
   *
   * 自绘模式（startHmi / startEncoder）没有屏幕采集会话，而长时任务
   * AUDIO_RECORDING 的豁免判据是"真的有采集会话在跑"。
   * 补一个「只采内录、不采屏、不开麦」的采集会话，才能让切后台不被冻结。
   *
   * 失败不阻断视频 —— 没有它只是切后台可能掉，前台画面照样推。
   *
   * ★ 顺带把内录 PCM 经 audioSink 转交引擎发车机（Ch3/9240）：
   *   官方 SDK 的 FEATURE_CONFIG_AUDIO_TRANSMISSION_MODE 默认 0=专用音频通道。
   */
  private startKeepAliveAudio(): void {
    try {
      const stage: number = carlifecodec.startAudioCapture(
        (data: ArrayBuffer, timestampUs: number, sourceType: number): void => {
          NativeHmiSource.audioFrames++;
          // 转交引擎（若有）：内录 PCM → MSG_MEDIA_DATA → 车机 Ch3/9240
          if (sourceType === 1 && CarLifeRuntime.audioSink !== null) {
            // sourceType 1 = 内录（系统播放音频）；2 = 麦克风（已关，正常不来）
            const sink = CarLifeRuntime.audioSink;
            if (sink !== null) {
              sink(new Uint8Array(data), timestampUs, sourceType);
            }
          }
        }
      );
      if (stage === 0) {
        CarLifeRuntime.addLog('[音频] 保活采集已启动');
      } else if (stage === 54) {
        // ALREADY_RUNNING —— 正常，切模式时不重起
      } else {
        CarLifeRuntime.addLog(`[音频] ⚠ 保活采集启动失败 stage=${stage}`);
      }
    } catch (e) {
      const err = e as Error;
      CarLifeRuntime.addLog(`[音频] 保活采集异常: ${err.message}`);
    }
  }

  /**
   * 自测：**不需要车机**，直接把「编码器 + 自绘渲染」跑起来。
   *
   * ## 为什么需要它
   *
   * 画面管线原本只在车机下发 98313（START）时才启动 —— 车机不在手边时，
   * 设置页永远显示「未运行」，什么都验证不了。这个入口让我们能独立验证：
   *   ① 渲染后端能不能建成（GPU OnScreen / CPU 位图）
   *   ② 编码器是否真的出帧（outputFrames 是否在涨）
   *   ③ 自愈有没有被触发
   * 出帧回调只计数、不外发（本来也没车机可发）。
   */
  startSelfTest(width: number, height: number, frameRate: number): boolean {
    if (this.running) {
      CarLifeRuntime.addLog('[自测] 画面通路已在运行，先「停止」再自测');
      return false;
    }
    const params: VideoParams = { width, height, frameRate };
    const ok: boolean = this.start(params, () => {
      // 自测不推流，帧内容丢弃
    }, (code: number, msg: string) => {
      CarLifeRuntime.addLog(`[自测] 编码错误 code=${code} ${msg}`);
    });
    if (ok) {
      this.selfTest = true;
      CarLifeRuntime.addLog('[自测] 已启动（无车机；仅验证渲染与编码出帧）');
    }
    return ok;
  }

  /** 是否处于自测模式（无车机） */
  get isSelfTest(): boolean {
    return this.selfTest;
  }

  requestKeyFrame(): void {
    if (this.running) {
      carlifecodec.requestKeyFrame();
    }
  }

  setFrameRate(frameRate: number): void {
    if (!this.running) {
      return;
    }
    const ret: number = carlifecodec.setFrameRate(frameRate);
    if (ret !== 0) {
      CarLifeRuntime.addLog(`[自绘] ⚠ 帧率调整失败（ret=${ret}），沿用原帧率`);
    }
  }

  // ==================== 兜底：截图推流 ====================

  /**
   * 兜底模式下喂一帧 RGBA 像素（由页面的 getSync 截图循环调用）。
   *
   * 尺寸必须与编码器配置一致（页面负责把截图尺寸对齐到 canvasWidth/Height）。
   */
  feedScreenshot(rgba: ArrayBuffer, w: number, h: number): void {
    if (!this.running || !this.fallback) {
      // ★ 诊断：区分"没启动/模式不对"和"推失败"（2026-10-15 排查引擎截图丢帧）
      NativeHmiSource.feedSkipReason = !this.running ? '管线未运行' : '不在页面喂图模式';
      return;
    }
    const ret: number = carlifecodec.pushFrame(rgba, w, h);
    if (ret !== 0) {
      // 返回码：-1 编码器未运行 / -2 参数坏 / -3 EGL 失败 / -4 swap 失败
      NativeHmiSource.lastFeedCode = ret;
    } else {
      NativeHmiSource.feedOkCount++;
      NativeHmiSource.lastFeedCode = 0;
      NativeHmiSource.feedSkipReason = '';
    }
  }

  /** ★ 诊断：feedScreenshot 被跳过的原因（空 = 没有被跳过） */
  static feedSkipReason: string = '';
  /** ★ 诊断：最近一次 pushFrame 返回码（0 = 成功） */
  static lastFeedCode: number = 0;
  /** ★ 诊断：pushFrame 成功次数 */
  static feedOkCount: number = 0;

  // ==================== 渲染后端控制 ====================

  /**
   * 手动切换渲染后端。
   *
   * 用途：GPU OnScreen 后端若在真机上画不出东西（黑屏），切 CPU 即可看到画面。
   * 仅在**自绘模式**下有效；兜底模式忽略。
   */
  setBackend(backend: number): void {
    if (!this.running || this.fallback) {
      return;
    }
    carlifecodec.setHmiBackend(backend);
    const name: string = backend === HMI_BACKEND_CPU ? 'CPU 位图'
      : (backend === HMI_BACKEND_GPU ? 'GPU OnScreen' : '自动');
    CarLifeRuntime.addLog(`[自绘] 已请求切换后端 → ${name}`);
  }

  // ==================== HMI 状态推送 ====================

  /** 切换页面（0 首页 / 1 导航） */
  setPage(page: number): void {
    if (this.payload.page === page) {
      return;
    }
    this.payload.page = page;
    this.push();
  }

  setConnected(connected: boolean): void {
    const v: number = connected ? 1 : 0;
    if (this.payload.connected === v) {
      return;
    }
    this.payload.connected = v;
    this.push();
  }

  /** 更新导航卡（距离 / 路名 / 提示） */
  setNavi(turnType: number, distanceText: string, distanceUnit: string,
          road: string, hint: string, nextHint: string, progress: number): void {
    const n = this.payload.navi;
    if (n.turnType === turnType && n.distanceText === distanceText
      && n.distanceUnit === distanceUnit && n.road === road
      && n.hint === hint && n.nextHint === nextHint && n.progress === progress) {
      return;
    }
    n.turnType = turnType;
    n.distanceText = distanceText;
    n.distanceUnit = distanceUnit;
    n.road = road;
    n.hint = hint;
    n.nextHint = nextHint;
    n.progress = progress;
    this.push();
  }

  /** 更新音频迷你卡 */
  setAudio(title: string, artist: string, positionMs: number, durationMs: number,
           playing: boolean): void {
    const a = this.payload.audio;
    const p: number = playing ? 1 : 0;
    if (a.title === title && a.artist === artist && a.positionMs === positionMs
      && a.durationMs === durationMs && a.playing === p) {
      return;
    }
    a.title = title;
    a.artist = artist;
    a.positionMs = positionMs;
    a.durationMs = durationMs;
    a.playing = p;
    this.push();
  }

  /** 更新首页顶部状态栏（时间 / 信号 / 电量） */
  setStatus(clock: string, signalBars: number, carrier: string, batteryPct: number): void {
    const s = this.payload.status;
    if (s.clock === clock && s.signalBars === signalBars && s.carrier === carrier
      && s.batteryPct === batteryPct) {
      return;
    }
    s.clock = clock;
    s.signalBars = signalBars;
    s.carrier = carrier;
    s.batteryPct = batteryPct;
    this.push();
  }

  /** 更新首页天气卡 */
  setWeather(tempC: number, condition: string, city: string, airQuality: string): void {
    const w = this.payload.weather;
    if (w.tempC === tempC && w.condition === condition && w.city === city
      && w.airQuality === airQuality) {
      return;
    }
    w.tempC = tempC;
    w.condition = condition;
    w.city = city;
    w.airQuality = airQuality;
    this.push();
  }

  /** 更新首页通勤/到达卡 */
  setEta(minutes: number, arriveAt: string): void {
    const e = this.payload.eta;
    if (e.minutes === minutes && e.arriveAt === arriveAt) {
      return;
    }
    e.minutes = minutes;
    e.arriveAt = arriveAt;
    this.push();
  }

  /** 整包推送当前状态（native 侧线程安全、非阻塞） */
  push(): void {
    if (!this.running || this.fallback) {
      return;   // 兜底模式下画面来自截图，推状态没有意义
    }
    carlifecodec.setHmiState(this.payload);
  }

  // ==================== 诊断 ====================

  /** 自绘运行诊断快照 */
  diag(): HmiDiag {
    if (!this.running) {
      return {
        running: false, fallback: false, backend: -1,
        frames: 0, outputFrames: 0, selfHealed: false, flushCode: 0
      };
    }
    if (this.fallback) {
      return {
        running: true, fallback: true, backend: -1,
        frames: 0, outputFrames: 0, selfHealed: false, flushCode: 0
      };
    }
    const s = carlifecodec.hmiStats();
    return {
      running: s.running,
      fallback: false,
      backend: s.backend,
      frames: s.frames,
      outputFrames: s.outputFrames,
      selfHealed: s.selfHealed,
      flushCode: s.flushCode
    };
  }

  /** 自绘运行诊断（单行文本） */
  stats(): string {
    if (!this.running) {
      return '未运行';
    }
    if (this.fallback) {
      return '截图推流兜底（前台可用）';
    }
    const s = carlifecodec.hmiStats();
    const be: string = s.cpuBackend ? 'CPU 后端' : 'GPU 后端';
    const head: string = this.selfTest ? '自测｜' : '';
    return `${head}帧 ${s.frames}｜编码器出帧 ${s.outputFrames}｜${be}`
      + `｜提交 ${s.flushCode === 0 ? '正常' : '异常(' + s.flushCode + ')'}`
      + (s.selfHealed ? '｜★已自愈' : '');
  }

  /** 按分辨率与帧率估算合理码率 */
  private static bitrateFor(width: number, height: number, fps: number): number {
    const raw: number = Math.round(width * height * fps * 0.15);
    const MIN: number = 1500000;
    const MAX: number = 12000000;
    if (raw < MIN) {
      return MIN;
    }
    if (raw > MAX) {
      return MAX;
    }
    return raw;
  }
}

// ===========================================================================
// 离线自绘自检的结果与执行器
//
// 为什么放在这个文件里：它验的就是「自绘渲染器能不能画」，属于同一个主题；
// 但它**不走 NativeHmiSource 的实例**，因为自检用的是 native 侧独立的
// HmiRenderer 实例，跟运行中的 HMI 互不干扰。
// ===========================================================================

/** 自检结果（给 UI 展示用，已整理成人类可读的形态） */
export interface HmiSelfCheckOutcome {
  /** 自检整体是否成功 */
  ok: boolean;
  /** 失败码：0 = 成功，1 = CPU 位图后端失败，2 = 字体集合失败 */
  failCode: number;
  /** CPU 位图后端是否建成 */
  cpuBackendOk: boolean;
  width: number;
  height: number;
  /** 首页绘制耗时（毫秒） */
  homeMs: number;
  /** 导航页绘制耗时（毫秒） */
  navMs: number;
  /** 一句话结论 */
  text: string;
  /** 落盘的 PNG 路径（空串 = 没落成） */
  homePath: string;
  navPath: string;
  /** 像素是否拿到（但不一定落盘成功） */
  homePixels: boolean;
  navPixels: boolean;
}

/**
 * 自绘渲染器的离线自检（**不需要编码器 / 车机 / window**）。
 *
 * ## 为什么必须要有这条路
 *
 * 2026-10-14 在模拟器上定到了硬结论：**这台模拟器没有任何视频编码器**
 * （`CreateByMime(video/avc) 失败；HEVC 探测: 也不可用`），于是
 * 「自绘 → 编码器 → 推流」整条链路的运行时验证全部卡死 —— 连
 * `startSelfTest` 都在 stage=1 就退出了。
 *
 * 但「画得出来吗」这个问题只依赖 Skia 的 CPU 位图后端，**跟编码器无关**，
 * 而且是同步的。所以把它单独拎出来验；这是唯一一条不依赖硬件编码器的
 * 证据链，也是这台模拟器上能拿到的最强证据。
 *
 * ## 落盘
 *
 * native 侧 `native_drawing` 没有图像编码接口，所以返回的是 **RGBA8888 裸像素**；
 * 这里用 image kit 的 `createPixelMapSync` + `ImagePacker` 编成 PNG 写进
 * 应用沙箱 files 目录，路径一并返回，方便 `hdc file recv` 拉回来肉眼比对。
 */
export async function runHmiSelfCheck(width: number, height: number): Promise<HmiSelfCheckOutcome> {
  const out: HmiSelfCheckOutcome = {
    ok: false, failCode: -1, cpuBackendOk: false,
    width: width, height: height, homeMs: 0, navMs: 0,
    text: '', homePath: '', navPath: '', homePixels: false, navPixels: false
  };

  let r: carlifecodec.HmiSelfCheckResult;
  try {
    r = carlifecodec.runHmiSelfCheck({ width: width, height: height });
  } catch (e) {
    const err = e as Error;
    out.text = `自检调用异常：${err.message}`;
    CarLifeRuntime.addLog(`[自检] ✗ ${out.text}`);
    return out;
  }

  out.ok = r.ok;
  out.failCode = r.failCode;
  out.cpuBackendOk = r.cpuBackendOk === 1;
  out.width = r.width;
  out.height = r.height;
  out.homeMs = r.homeMs;
  out.navMs = r.navMs;
  out.homePixels = r.home !== null;
  out.navPixels = r.nav !== null;

  if (!r.ok) {
    out.text = r.failCode === 1 ? 'CPU 位图后端建不起来（Skia 不可用？）'
      : (r.failCode === 2 ? '字体集合创建失败' : `自检失败 code=${r.failCode}`);
    CarLifeRuntime.addLog(`[自检] ✗ ${out.text}`);
    return out;
  }

  // ---- 落盘：RGBA8888 裸像素 → PNG（native_drawing 没有编码接口，只能这边做）----
  const dir: string = getContext().filesDir;
  if (r.home !== null) {
    out.homePath = await dumpPng(r.home, r.width, r.height, `${dir}/hmi_home.png`, 'home');
  }
  if (r.nav !== null) {
    out.navPath = await dumpPng(r.nav, r.width, r.height, `${dir}/hmi_navi.png`, 'navi');
  }

  const saved: number = (out.homePath.length > 0 ? 1 : 0) + (out.navPath.length > 0 ? 1 : 0);
  out.text = `渲染可用（CPU 位图后端 ✓）｜首页 ${r.homeMs.toFixed(1)}ms`
    + `｜导航页 ${r.navMs.toFixed(1)}ms｜落盘 ${saved}/2`;
  CarLifeRuntime.addLog(`[自检] ✓ ${out.text}`);
  return out;
}

/**
 * 把一帧 RGBA8888 裸像素编成 PNG 写盘。
 *
 * @returns 成功返回文件绝对路径；失败返回空串（原因已进日志）
 */
async function dumpPng(rgba: ArrayBuffer, width: number, height: number,
                       path: string, tag: string): Promise<string> {
  const want: number = width * height * 4;
  if (rgba.byteLength < want) {
    CarLifeRuntime.addLog(`[自检] ✗ ${tag} 像素不足 ${rgba.byteLength} < ${want}`);
    return '';
  }

  // RGBA8888 在 ArkTS 侧的枚举名是 RGBA_8888
  const info: image.InitializationOptions = {
    size: { width: width, height: height },
    srcPixelFormat: image.PixelMapFormat.RGBA_8888,
    pixelFormat: image.PixelMapFormat.RGBA_8888,
    editable: false,
    alphaType: image.AlphaType.OPAQUE
  };

  let pm: image.PixelMap | null = null;
  try {
    pm = image.createPixelMapSync(rgba, info);
  } catch (e) {
    const err = e as Error;
    CarLifeRuntime.addLog(`[自检] ✗ ${tag} createPixelMapSync: ${err.message}`);
    return '';
  }
  if (pm === null) {
    CarLifeRuntime.addLog(`[自检] ✗ ${tag} createPixelMapSync 返回 null`);
    return '';
  }

  const packer: image.ImagePacker = image.createImagePacker();
  try {
    const buf: ArrayBuffer = await packer.packToData(pm, {
      format: 'image/png',
      quality: 95
    });
    await writeFileBytes(path, buf);
    CarLifeRuntime.addLog(`[自检] ✓ ${tag} → ${path}（${Math.round(buf.byteLength / 1024)}KB）`);
    return path;
  } catch (e) {
    const err = e as Error;
    CarLifeRuntime.addLog(`[自检] ✗ ${tag} PNG 编码/写盘失败: ${err.message}`);
    return '';
  } finally {
    packer.release();
    pm.release();
  }
}

/** 写二进制文件（沙箱内） */
async function writeFileBytes(path: string, data: ArrayBuffer): Promise<void> {
  const f: fileIo.File = fileIo.openSync(path,
    fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
  try {
    await fileIo.write(f.fd, data);
    fileIo.fsyncSync(f.fd);
  } finally {
    fileIo.closeSync(f);
  }
}
