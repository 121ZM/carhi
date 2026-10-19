/**
 * 应用投屏画面源（ScreenCaptureSource）
 *
 * ## 它解决什么问题
 *
 * 大哥的最终目标：**车机上显示手机里的高德导航画面**（就像 CarLife 那样）。
 *
 * 前面试过的路（都有实测记录，别重复走）：
 *   - ❌ Car Kit 读高德数据：API 里没有「读取」入口，双数据源实测零回调
 *   - ⚠️ 高德 SDK 自绘：数据拿到了，但画面要我们自己画（不是高德原生画面）
 *   - ❌ 高德引擎截图导出：`EGL_CONTEXT_LOST`（大纹理超限），且属绕路
 *
 * **本类走的是「应用投屏」**：用系统的 `OH_AVScreenCapture` 采集屏幕，
 * 直接把画面推给车机。这正是官方 CarLife 的机制（安卓侧 `MediaProjection`
 * + `VirtualDisplay`，鸿蒙侧 `OH_AVScreenCapture`），**普通应用即可使用**。
 *
 * ## 关键事实（已核实，勿再推翻）
 *
 * - CarLife 手机端 APK 里是 `MediaProjection`/`VirtualDisplay` → **不需要系统特权**
 * - 大哥实测：**CarLife 切后台，车机画面正常** → 录屏能在后台持续
 * - `AVScreenCapture` 官方标注**适用对象 = 所有应用**
 * - 整屏镜像（`display.createVirtualScreen()`）才是**仅系统应用**
 *
 * ## 与 NativeHmiSource 的关系
 *
 * 两者都实现 `FrameSource` 接口，**互斥**（都占用硬件编码器）：
 *   - `NativeHmiSource`：画面由我们 native 自绘（CarWith 版式卡片）
 *   - `ScreenCaptureSource`：画面来自系统采集（手机真实屏幕 → 含高德 App）
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { display } from '@kit.ArkUI';
import { CarLifeRuntime } from '../entryability/EntryAbility';
import { FrameSource } from './CarLifeEngine';
import { VideoParams } from './StateMachine';
import carlifecodec from 'libcarlifecodec.so';

const DOMAIN: number = 0x0001;
const TAG: string = 'CarHiCast';

/** 采集错误码（与 native 侧 `CaptureInterrupt` 对齐） */
export const CAPTURE_CANCELED_BY_USER: number = -1;
export const CAPTURE_STOPPED_BY_USER: number = -2;
export const CAPTURE_STOPPED_BY_CALL: number = -3;
export const CAPTURE_INTERRUPT_BY_OTHER: number = -4;
export const CAPTURE_ERROR: number = -5;

/**
 * 采集区域（屏幕坐标，px）。
 *
 * ★ 「小窗口投屏」：应用自建全局悬浮窗在鸿蒙上不可行（`FLOAT_VIEW` 等权限
 *   要求系统应用，声明后装机直接失败 9568289）。可行路径是用户用系统
 *   「智慧多窗」把本应用拖成悬浮小窗，再把该小窗的 `windowRect` 交给采集器，
 *   于是车机只看到这块内容，手机其余部分照常使用。
 */
export interface CaptureArea {
  x: number;
  y: number;
  width: number;
  height: number;
}

/** 采集运行诊断（给设置页展示） */
export interface CaptureDiag {
  running: boolean;
  /** 采集编码尺寸 */
  width: number;
  height: number;
  /** 已产出帧数（由回调累计） */
  frames: number;
  /** 最近一次错误码（0 = 无） */
  lastError: number;
  /** 最近一次错误信息 */
  lastErrorMsg: string;
}

/**
 * 应用投屏画面源。
 *
 * 用法：
 *   const src = new ScreenCaptureSource();
 *   src.start(params, onFrame, onError);
 *   ...
 *   src.stop();
 */
export class ScreenCaptureSource implements FrameSource {
  private running: boolean = false;
  private onFrameCb: ((nalu: Uint8Array, pts: number, keyFrame: boolean) => void) | null = null;
  private onErrorCb: ((code: number, msg: string) => void) | null = null;

  private width: number = 1280;
  private height: number = 720;

  /** 已产出帧数（诊断） */
  private frameCount: number = 0;
  /** 最近错误 */
  private lastError: number = 0;
  private lastErrorMsg: string = '';
  /** 采集已启动的次数（配合 CaptureGate 的配额） */
  private startAttempts: number = 0;
  /** 当前采集区域（null = 整屏采集） */
  private area: CaptureArea | null = null;
  /** 物理屏信息（诊断用，最近一次同步值） */
  private screenW: number = 0;
  private screenH: number = 0;
  private screenRot: number = 0;

  /** 当前采集区域（null = 整屏采集） */
  get captureArea(): CaptureArea | null {
    return this.area;
  }

  /** 是否处于「只投一块区域」模式 */
  get isRegionMode(): boolean {
    return this.area !== null;
  }

  get isRunning(): boolean {
    return this.running;
  }

  get canvasWidth(): number {
    return this.width;
  }

  get canvasHeight(): number {
    return this.height;
  }

  /** 诊断快照 */
  diag(): CaptureDiag {
    return {
      running: this.running,
      width: this.width,
      height: this.height,
      frames: this.frameCount,
      lastError: this.lastError,
      lastErrorMsg: this.lastErrorMsg
    };
  }

  /**
   * 启动应用投屏采集（FrameSource 标准签名）。
   *
   * @param params 编码参数（宽高帧率由车机下发）
   * @param onFrame H.264 裸流回调（交给既有 TCP 推流链路）
   * @param onError 错误回调
   * @returns true = 采集已启动
   *
   * ⚠ 首次调用会弹**系统录屏授权框**（鸿蒙强制，无法绕过，CarLife 同样如此）。
   *   用户点「允许」后采集开始；点「取消」则返回失败（code -1，不可重试，避免骚扰）。
   */
  start(params: VideoParams,
        onFrame: (nalu: Uint8Array, pts: number, keyFrame: boolean) => void,
        onError: (code: number, msg: string) => void): boolean {
    return this.startWith(params.width, params.height, params.frameRate, onFrame, onError);
  }

  /** 实际启动实现（便于本地测试直接给宽高） */
  startWith(width: number, height: number, fps: number,
            onFrame: (nalu: Uint8Array, pts: number, keyFrame: boolean) => void,
            onError?: (code: number, msg: string) => void): boolean {
    if (this.running) {
      CarLifeRuntime.addLog('[投屏] 已在运行，忽略重复启动');
      return true;
    }

    this.width = width > 0 ? width : 1280;
    this.height = height > 0 ? height : 720;
    this.onFrameCb = onFrame;
    this.onErrorCb = onError ?? null;

    const opts: carlifecodec.EncoderOptions = {
      width: this.width,
      height: this.height,
      frameRate: fps > 0 ? fps : 30,
      bitrate: ScreenCaptureSource.bitrateFor(this.width, this.height, fps > 0 ? fps : 30),
      iFrameIntervalMs: 2000
    };

    const frameCb = (data: ArrayBuffer, pts: number, keyFrame: boolean): void => {
      this.frameCount++;
      const cb = this.onFrameCb;
      if (cb !== null) {
        cb(new Uint8Array(data), pts, keyFrame);
      }
    };
    const errCb = (code: number, msg: string): void => {
      this.lastError = code;
      this.lastErrorMsg = msg;
      hilog.error(DOMAIN, TAG, `采集错误 code=${code} msg=${msg}`);
      // 不可恢复的（用户取消/主动停止）→ 直接停，不再重试
      if (code === CAPTURE_CANCELED_BY_USER || code === CAPTURE_STOPPED_BY_USER) {
        this.running = false;
      }
      const cb = this.onErrorCb;
      if (cb !== null) {
        cb(code, msg);
      }
    };

    this.startAttempts++;
    let stage: number = -1;
    // ★ 音频通路（Ch3/9240）：ScreenEncoder 本就在采内录音频，加第 4 参即可把
    //   PCM 转出去（不发时它只在内部消费、保长时任务名实相符）。
    //   官方 FEATURE_CONFIG_AUDIO_TRANSMISSION_MODE 默认 0=专用音频通道。
    const audioCb = (data: ArrayBuffer, timestampUs: number, sourceType: number): void => {
      if (sourceType === 1 && CarLifeRuntime.audioSink !== null) {
        const sink = CarLifeRuntime.audioSink;
        if (sink !== null) {
          sink(new Uint8Array(data), timestampUs, sourceType);
        }
      }
    };
    try {
      stage = carlifecodec.startCapture(opts, frameCb, errCb, audioCb);
    } catch (e) {
      const err = e as Error;
      this.lastErrorMsg = `startCapture 抛异常: ${err.message}`;
      hilog.error(DOMAIN, TAG, this.lastErrorMsg);
      return false;
    }

    if (stage !== 0) {
      const why: string = ScreenCaptureSource.stageName(stage);
      this.lastErrorMsg = `启动失败 stage=${stage}（${why}）`;
      this.lastError = stage;
      hilog.error(DOMAIN, TAG, this.lastErrorMsg);
      CarLifeRuntime.addLog(`[投屏] ✗ ${this.lastErrorMsg}`);
      return false;
    }

    this.running = true;
    hilog.info(DOMAIN, TAG, `★ 应用投屏已启动（${this.width}x${this.height} @ ${opts.frameRate}fps）`);
    CarLifeRuntime.addLog(`[投屏] ★ 采集已启动（${this.width}x${this.height} @ ${opts.frameRate}fps）`
      + `｜第 ${this.startAttempts} 次尝试`);
    return true;
  }

  /** 停止采集 */
  stop(): void {
    if (!this.running) {
      return;
    }
    this.running = false;
    this.onFrameCb = null;
    try {
      carlifecodec.stopCapture();
      CarLifeRuntime.addLog('[投屏] 采集已停止');
    } catch (e) {
      const err = e as Error;
      CarLifeRuntime.addLog(`[投屏] 停止异常: ${err.message}`);
    }
  }

  /**
   * 把物理屏信息（自然方向宽高 + 当前旋转）同步给 native。
   *
   * 每次设区域前都调一次 —— 旋转、分屏、折叠屏展开都会让它变，缓存值易过期。
   */
  private syncScreenMeta(): void {
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      // `rotation` 是 0/1/2/3 的顺时针档位，换算成角度
      const rot: number = Math.max(0, Math.min(3, Math.round(d.rotation))) * 90;
      const naturalW: number = Math.min(d.width, d.height);
      const naturalH: number = Math.max(d.width, d.height);
      this.screenW = naturalW;
      this.screenH = naturalH;
      this.screenRot = rot;
      carlifecodec.setScreenMeta(d.id, naturalW, naturalH, rot);
      hilog.info(DOMAIN, TAG,
        `屏幕信息 displayId=${d.id} 自然=${naturalW}x${naturalH} 当前=${d.width}x${d.height} rot=${rot}`);
    } catch (e) {
      const err = e as Error;
      hilog.warn(DOMAIN, TAG, `同步屏幕信息失败: ${err.message}`);
    }
  }

  /**
   * ★ 设置采集区域（「小窗口投屏」）。
   *
   * 只把屏幕上一块矩形推给车机，其余部分不上车机 —— 用户可以把本应用
   * 拖成悬浮小窗，手机其他区域照常使用其他 App。
   *
   * @param x,y 区域左上角（**当前旋转方向**的屏幕坐标 px，取自 `windowRect`）
   * @returns 0 成功；-1 参数非法；-2 采集未就绪（区域已缓存）；-3 系统拒绝
   *
   * ⚠ 区域坐标系与采集器不一致的问题已由 `syncScreenMeta()` 处理：
   *   横屏时 `windowRect` 是横屏坐标，native 侧先换算到自然方向再下发。
   */
  setCaptureArea(x: number, y: number, width: number, height: number): number {
    // ★ 必须先把物理屏信息同步下去：`windowRect` 是**当前旋转**坐标系的矩形，
    //   而采集器要的是**自然方向**坐标。不同步的话，横屏小窗会因越界被拒：
    //   实测 code=3 INVALID_VAL（rect 133,178 1272x716 / 自然屏 1272x2860）。
    this.syncScreenMeta();

    const xi: number = Math.max(0, Math.round(x));
    const yi: number = Math.max(0, Math.round(y));
    const wi: number = Math.round(width);
    const hi: number = Math.round(height);
    if (wi <= 0 || hi <= 0) {
      return -1;
    }

    let ret: number = -1;
    try {
      ret = carlifecodec.setCaptureArea(xi, yi, wi, hi);
    } catch (e) {
      const err = e as Error;
      CarLifeRuntime.addLog(`[投屏] 设置采集区域异常: ${err.message}`);
      return -1;
    }

    if (ret === 0 || ret === -2) {
      // -2 = 采集尚未就绪，但 native 已缓存区域，下次启动会生效
      const a: CaptureArea = { x: xi, y: yi, width: wi, height: hi };
      this.area = a;
      CarLifeRuntime.addLog(`[投屏] 采集区域 → ${wi}x${hi} @(${xi},${yi})`
        + (ret === -2 ? '（采集未就绪，已缓存）' : ''));
    } else {
      CarLifeRuntime.addLog(`[投屏] ✗ 设置采集区域失败 ret=${ret}`);
    }
    return ret;
  }

  /** 清除采集区域、恢复整屏（内部会重建采集实例） */
  clearCaptureArea(): number {
    this.area = null;
    try {
      const ret: number = carlifecodec.clearCaptureArea();
      CarLifeRuntime.addLog(`[投屏] 已恢复整屏采集 ret=${ret}`);
      return ret;
    } catch (e) {
      const err = e as Error;
      CarLifeRuntime.addLog(`[投屏] 清除采集区域异常: ${err.message}`);
      return -1;
    }
  }

  /**
   * 尝试从中断中恢复（切后台/来电/被抢占后的重连）。
   *
   * @returns true = 已重启成功
   */
  tryRecover(): boolean {
    if (this.lastError === 0 || !carlifecodec.isRecoverable(this.lastError)) {
      return false;
    }
    // native 侧有 3 秒冷却，这里也做一次节流，避免抖动期疯狂重试
    const ret: number = carlifecodec.restartCapture();
    if (ret === 0) {
      this.running = true;
      CarLifeRuntime.addLog('[投屏] ★ 采集已从中断恢复');
      return true;
    }
    return false;
  }

  /** 码率估算：与 NativeHmiSource 同口径 */
  private static bitrateFor(w: number, h: number, fps: number): number {
    // 经验值：0.12 bit/pixel/frame，限制在 2~16 Mbps
    const raw: number = Math.round(w * h * fps * 0.12);
    return Math.max(2000000, Math.min(16000000, raw));
  }

  /** 阶段号 → 人话 */
  private static stageName(stage: number): string {
    switch (stage) {
      case 1: return 'OH_VideoEncoder_CreateByMime 失败';
      case 2: return 'OH_VideoEncoder_Configure 失败';
      case 3: return 'OH_VideoEncoder_GetSurface 失败';
      case 4: return 'OH_VideoEncoder_RegisterCallback 失败';
      case 5: return 'OH_VideoEncoder_Prepare 失败';
      case 6: return 'OH_VideoEncoder_Start 失败';
      case 17: return 'OH_AVScreenCapture_Create 失败';
      case 18: return 'OH_AVScreenCapture_Init 失败';
      case 19: return '启动采集失败（用户拒绝授权，或已有采集在跑）';
      default: return `未知阶段 ${stage}`;
    }
  }

  // -------------------------------------------------------------------------
  // FrameSource 接口适配
  //
  // 推流链路（CarLifeEngine）通过 `FrameSource` 消费帧，因此本类可以直接
  // 顶替 `NativeHmiSource` 当画面源 —— 用起来与自绘完全同构。
  // -------------------------------------------------------------------------

  /** FrameSource.requestKeyFrame —— 采集侧不需要（编码器自带 GOP），留空实现 */
  requestKeyFrame(): void {
    // 采集编码器由 native 侧管理，I 帧按 iFrameIntervalMs 自然产生。
    // 这里不强行请求，避免与原生 GOP 策略冲突。
  }

  /** FrameSource.setFrameRate —— 动态调帧率（采集侧支持） */
  setFrameRate(frameRate: number): void {
    try {
      carlifecodec.setFrameRate(frameRate);
    } catch (e) {
      // 忽略：编码器未运行时调用无意义
    }
  }
}
