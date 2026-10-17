/**
 * CarHi 画面编码 Native 模块（libcarlifecodec.so）类型声明
 *
 * ★ 2026-10-13 路线 A 重置：不再走录屏（已移除 OH_AVScreenCapture）。
 *   本模块现在只做一件事：**把外部画布（XComponent / GL）接到硬件编码器**，
 *   产出 H.264 裸流交给 ArkTS，再由 ArkTS 走 TCP 发车机。
 *
 *   为什么编码必须在 C++：ArkTS 侧没有视频编码 API（SDK 全量检索确认）。
 */

/** 编码参数 —— 路线 A 下尺寸由我们自己定，不再迁就手机物理屏 */
export interface EncoderOptions {
  /** 画面宽度（px） */
  width: number;
  /** 画面高度（px） */
  height: number;
  /** 期望帧率 */
  frameRate: number;
  /** 码率（bit/s） */
  bitrate: number;
  /** I 帧间隔（毫秒），默认 2000 */
  iFrameIntervalMs?: number;
}

/**
 * 帧回调。
 * @param data H.264 Annex-B 裸流（含 SPS/PPS 与 SEI），直接可发车机
 * @param pts 时间戳（微秒）
 * @param keyFrame 是否关键帧
 */
export type FrameCallback = (data: ArrayBuffer, pts: number, keyFrame: boolean) => void;

/** 错误回调 */
export type ErrorCallback = (code: number, msg: string) => void;

/** 原始音频回调：data 是独立的 PCM ArrayBuffer；sourceType 1=内录，2=麦克风 */
export type AudioFrameCallback = (data: ArrayBuffer, timestampUs: number, sourceType: number) => void;

/** 音频采集诊断快照 */
export interface AudioCaptureStats {
  running: boolean;
  innerBuffers: number;
  micBuffers: number;
  videoBuffers: number;
  lastStage: number;
  interrupted: number;
  queueDrops: number;
}

/** 编码器实际输出尺寸 */
export interface EncodedSize {
  width: number;
  height: number;
}

/**
 * 启动编码管线，并绑定到指定画布 Surface。
 *
 * @param surfaceId 画布的 Surface id。**ArkTS 的 XComponent 暴露的是 string**，
 *                  底层同时接受 bigint / string / number 三种形态。
 *                  传空串或 '0' 表示"先建编码器、暂不绑画布"（此时不产帧）。
 * @returns 0 成功；非 0 为失败阶段号（见 cpp/canvas_encoder.h 的 StartStage）
 */
export const startEncoder: (surfaceId: string | number | bigint, options: EncoderOptions,
                            onFrame: FrameCallback, onError?: ErrorCallback) => number;

/**
 * 运行中补绑 / 换绑画布 Surface。
 * 用于「XComponent 晚于编码器就绪」的场景（如页面重建后）。
 * @returns 0 成功；非 0 失败
 */
export const attachSurface: (surfaceId: string | number | bigint) => number;

/** 停止并释放编码资源 */
export const stopEncoder: () => void;

/** 请求立即编码一个 I 帧（车机刚连上时用，避免等一个 GOP） */
export const requestKeyFrame: () => void;

/**
 * 运行中动态调整编码帧率。
 *
 * 对应车机下发的 98316（FRAME_RATE_CHANGE）。走编码器软刷新，
 * **不重建编码管线** —— 重建会让车机侧重新等 I 帧，表现为掉线。
 *
 * @param frameRate 目标帧率（fps）
 * @returns 0 成功；非 0 失败（原帧率继续生效）
 */
export const setFrameRate: (frameRate: number) => number;

/**
 * 前台推流：把一帧 RGBA 像素画进编码器输入 surface。
 * @param rgba RGBA8888 像素数据（来自 pixelMap.readPixelsToBufferSync）
 * @returns 0 成功；负数失败
 * @since 前台推流通路（2026-10-14）
 */
export const pushFrame: (rgba: ArrayBuffer, width: number, height: number) => number;

/** 编码管线是否在运行 */
export const isRunning: () => boolean;

/** 编码器实际输出尺寸（可能与请求值不同，硬件会按对齐调整） */
export const encodedSize: () => EncodedSize;

/** 管线验证结果 */
export interface ProbeResult {
  /** 是否跑通（有帧产出） */
  ok: boolean;
  /** 编码器实际宽高 */
  encWidth: number;
  encHeight: number;
  /** 是否取到编码器输入 surface 的 id（0/1） */
  surfaceIdOk: number;
  /** 编码器输入 surface 的 id（字符串形式，可能超 double 精度） */
  surfaceId: string;
  /** EGL display / EGLSurface 是否建成功（0/1） */
  eglOk: number;
  eglSurfaceOk: number;
  /** 喂进去的帧数（eglSwapBuffers 次数） */
  swapCount: number;
  /** 编码器实际吐出的帧数 */
  outputFrames: number;
  /** 首帧 pts（-1 表示没有） */
  firstOutputPts: number;
  /** 最后走到的阶段名 */
  stage: string;
  /** 失败原因（空串表示无错） */
  error: string;
}

/**
 * ★ 路线 A 机制验证：往编码器自己的输入 surface 画 → 能否出帧。
 *
 * A2（把 XComponent 的 surfaceId 交给编码器）已证伪：编码器与 XComponent
 * 各持一个 surface，鸿蒙无 API 连通，所以永远 0 帧。
 * A1（GL 直画）/ β（ArkUI 渲染后拷贝）的共同地基是「能往编码器 surface 写」，
 * 本接口就是验证这条地基。
 *
 * ⚠ **同步阻塞** seconds 秒，调用方须自行禁用按钮并提示用户。
 * ⚠ 编码器是独占资源，调用前应确保没有别的实例在跑（先 stopEncoder）。
 *
 * @param width  编码宽（偶数）
 * @param height 编码高（偶数）
 * @param seconds 持续秒数（1~15）
 */
export const runPipelineProbe: (width: number, height: number, seconds: number) => ProbeResult;

// ===========================================================================
// 路线 A1：原生自绘 HMI（2026-10-14）
//
// 与 startEncoder 的区别：**不需要外部 surfaceId**。画面由 native 自己的
// 渲染线程用 OH_Drawing(Skia) 直接画进编码器的输入 surface，
// 所以切后台/息屏都不会停 —— 这是"后台推流"的根据。
// ===========================================================================

/** HMI 页面：0 = 首页（左图标栏 + 中列卡片 + 地图）；1 = 导航页（左图标栏 + 纯地图） */
export type HmiPage = number;

/** 转向类型：0 无 / 1 左转 / 2 右转 / 3 直行 / 4 到达 */
export type HmiTurnType = number;

/** 导航卡内容 */
export interface HmiNaviState {
  /** 转向类型，见 HMI_TURN_* */
  turnType?: number;
  /** 剩余距离（米），仅诊断用 */
  distanceM?: number;
  /** 距离数字文本，如 "300" / "1.2" */
  distanceText?: string;
  /** 距离单位，如 "m" / "km" */
  distanceUnit?: string;
  /** 路名，如 "科技路" */
  road?: string;
  /** 动作提示，如 "前方路口右转进入科技路" */
  hint?: string;
  /** 下一步提示，如 "然后 直行 1.2 km" */
  nextHint?: string;
}

/** 音频迷你卡内容 */
export interface HmiAudioState {
  title?: string;
  artist?: string;
  positionMs?: number;
  durationMs?: number;
  /** 1 = 播放中（画暂停图标），0 = 暂停（画播放图标） */
  playing?: number;
}

/** HMI 全量状态 */
export interface HmiStatePayload {
  page?: number;
  connected?: number;
  navi?: HmiNaviState;
  audio?: HmiAudioState;
}

/**
 * 启动「编码器 + 原生自绘 HMI」。
 *
 * @param options 编码参数（宽高会被向下取偶）
 * @param onFrame H.264 裸流回调
 * @param onError 错误回调（可选）
 * @returns 0 成功；
 *          1..7 编码器失败阶段（见 canvas_encoder.h StartStage）；
 *          8    拿不到编码器输入 window；
 *          9    HmiRenderer 起不来
 */
export const startHmi: (options: EncoderOptions, onFrame: FrameCallback,
                        onError?: ErrorCallback) => number;

/** 推送 HMI 状态（线程安全，非阻塞） */
export const setHmiState: (state: HmiStatePayload) => void;

/** 停止自绘渲染与编码器 */
export const stopHmi: () => void;

/**
 * 渲染后端选择（数值见 ArkTS 侧 NativeHmiSource 的 HMI_BACKEND_* 常量）。
 * 0 = AUTO（默认，GPU 优先 + 自愈）/ 1 = 强制 GPU / 2 = 强制 CPU
 */
export type HmiBackend = number;

/**
 * 手动切换渲染后端（线程安全，渲染线程下一帧生效）。
 *
 * 用途：万一 GPU OnScreen 后端在真机上画不出东西（黑屏），
 * 切到 CPU 位图后端即可看到画面（那条 GL 上传通路已实测出过帧）。
 *
 * @param backend 0 = AUTO（默认）/ 1 = 强制 GPU / 2 = 强制 CPU
 */
export const setHmiBackend: (backend: HmiBackend) => void;

/** HMI 运行诊断 */
export interface HmiStats {
  running: boolean;
  /** true = 当前在 CPU 位图后端 */
  cpuBackend: boolean;
  /** 当前后端：0 = GPU OnScreen，1 = CPU 位图，-1 = 未运行 */
  backend: number;
  /** 是否发生过自愈（GPU 提交了帧但编码器不出帧 → 自动退 CPU） */
  selfHealed: boolean;
  /** 渲染器已提交帧数 */
  frames: number;
  /** 编码器累计输出帧数（= 真正进编码器的画面数） */
  outputFrames: number;
  /** 最近一次提交结果，0 = 成功 */
  flushCode: number;
}

export const hmiStats: () => HmiStats;

// ===========================================================================
// 离线自检：渲染器 ≠ 编码器（2026-10-14）
//
// 为什么要有它：整条「自绘 → 编码器 → 推流」的运行时验证被编码器卡住。
// 有些环境（典型是模拟器）**根本没有视频编码器**（AVC/HEVC 全不可用），
// 于是「画得出来吗、后端是哪个、一帧多久」这些问题一个都问不出去。
//
// 但绘图只依赖 Skia 的 CPU 位图后端，**跟编码器完全无关**，而且是同步的。
// 所以把它单独拎出来验 —— 这是唯一一条不依赖硬件编码器的证据链。
// ===========================================================================

/** 自检参数 */
export interface HmiSelfCheckOptions {
  /** 画布宽（< 64 按 1280 处理） */
  width?: number;
  /** 画布高（< 64 按 720 处理） */
  height?: number;
}

/**
 * 自检结果。
 *
 * ⚠ `home` / `nav` 是 **RGBA8888** 裸像素（不是 PNG）。
 *   native_drawing 里没有图像编码接口，落盘由 ArkTS 侧 image kit 负责。
 *   长度 = width * height * 4。
 */
export interface HmiSelfCheckResult {
  /** 自检是否整体成功（failCode === 0） */
  ok: boolean;
  /** 0 = 成功；1 = CPU 位图后端建不起来；2 = 字体集合创建失败 */
  failCode: number;
  /** CPU 位图后端是否建成（1 = 是）—— 直接回答"这条后端可用吗" */
  cpuBackendOk: number;
  width: number;
  height: number;
  /** 首页绘制耗时（毫秒） */
  homeMs: number;
  /** 导航页绘制耗时（毫秒） */
  navMs: number;
  /** 像素交付码：0 = 成功，-2 = 尺寸不符 */
  giveHomeCode: number;
  giveNavCode: number;
  /** 首页 RGBA8888 像素，失败为 null */
  home: ArrayBuffer | null;
  /** 导航页 RGBA8888 像素，失败为 null */
  nav: ArrayBuffer | null;
}

/**
 * 跑一次离线自绘自检（同步）。
 *
 * **不需要编码器、不需要车机、不需要 window、不起渲染线程**，
 * 内部用独立的 HmiRenderer 实例，不干扰正在运行的 HMI。
 *
 * ⚠ 同步阻塞，1280x720 两页通常几十毫秒，但低端机可能更久。
 *   调用方应避免在 UI 帧回调里调用。
 */
export const runHmiSelfCheck: (options?: HmiSelfCheckOptions) => HmiSelfCheckResult;


// ===========================================================================
// ★ 应用投屏：屏幕采集（OH_AVScreenCapture）
//
// 与 startHmi（native 自绘）的本质区别：**画面不是我们画的**，
// 而是系统采集屏幕得来的 —— 因此能录到**手机上的其它 App**（如高德地图）。
// 官方 CarLife 用的也是这一机制（安卓侧为 MediaProjection + VirtualDisplay）。
//
// ⚠ 与 startEncoder / startHmi **互斥**：三者都占用硬件编码器，
//   同一时刻只能有一个在跑（上层须先 stop 再 start 另一个）。
// ===========================================================================

/**
 * 启动屏幕采集 + 编码。
 *
 * 数据流：OH_AVScreenCapture ──Surface──▶ OH_VideoEncoder ──H.264──▶ onFrame
 * （全程零拷贝，画面不经 CPU 搬运）
 *
 * @param options 编码参数
 * @param onFrame H.264 Annex-B 裸流回调
 * @param onError 错误回调（可选）
 * @returns 0 成功；其余为失败阶段号：
 *          1..6 编码器阶段（见 canvas_encoder.h StartStage）
 *          17 = OH_AVScreenCapture_Create 失败
 *          18 = OH_AVScreenCapture_Init 失败
 *          19 = StartScreenCaptureWithSurface 失败（常见：用户拒绝授权）
 */
export const startCapture: (options: EncoderOptions, onFrame: FrameCallback,
                            onError?: ErrorCallback,
                            onAudioFrame?: AudioFrameCallback) => number;

/** 停止采集并释放资源（幂等） */
export const stopCapture: () => void;

/**
 * 重启采集（抖动/中断后的恢复）。
 *
 * 内部有 3 秒冷却：低于该间隔的重复调用会被忽略 —— 重建采集会换掉编码器
 * Surface，车机侧必须等下一个 I 帧才能恢复画面，频繁重建等于持续黑屏。
 *
 * @returns 0 成功；非 0 失败
 */
export const restartCapture: () => number;

/** 采集管线是否在运行 */
export const isCaptureRunning: () => boolean;

/**
 * ★ 设置采集区域（「小窗口投屏」）—— 只把屏幕上一块矩形推给车机。
 *
 * 对应 `OH_AVScreenCapture_SetCaptureArea`（@since 20）。采集启动前/后都能调，
 * 运行中可动态改（拖动小窗可实时跟随）。
 *
 * @param x,y 区域左上角，**屏幕坐标 px**（与 `window.getWindowProperties().windowRect` 同口径）
 * @param width,height 区域尺寸 px（必须 > 0）
 * @returns 0 成功；-1 参数非法；-2 采集未就绪（区域已缓存，下次启动生效）；-3 系统拒绝
 *
 * ⚠ 区域不得跨屏；失败时系统沿用上一次的区域。
 */
export const setCaptureArea: (x: number, y: number, width: number, height: number) => number;

/**
 * 清除采集区域、恢复整屏。
 *
 * 官方无「清除区域」接口，内部靠重建采集实例实现；受 `restartCapture` 的
 * 冷却期限制 —— 冷却期内调用会返回成功但**不会**真正重建，区域仍然生效。
 *
 * @returns 0 成功；非 0 失败（同 restartCapture 的阶段号）
 */
export const clearCaptureArea: () => number;

/**
 * 该错误码是否属于「可恢复」（上层据此决定要不要 restartCapture）。
 *
 * 可恢复：来电打断(-3) / 被其他应用抢占(-4) / 底层采集错误(-5)
 * 不可恢复：用户取消授权(-1) / 用户主动停止(-2)
 */
export const isRecoverable: (code: number) => boolean;

/** 采集编码器的实际输出尺寸 */
export const captureEncodedSize: () => EncodedSize;

// ===========================================================================
// 音频采集（后台保活 + PCM 内录）
//
// KeepAliveCapture：只采系统播放音频（不开屏幕、不开麦），
// 唯一使命是让长时任务 AUDIO_RECORDING "名实相符"，避免切后台被冻结。
// 同时把原始 PCM 回调给 ArkTS，供后续写入 CarLife 音频通道（Task 11）。
// ===========================================================================

/**
 * 启动仅内录采集。
 *
 * @param onAudioFrame PCM 回调（data: ArrayBuffer, timestampUs: number, sourceType: number）
 *   sourceType: 1 = 内录，2 = 麦克风
 * @returns 0 成功；51 = Create 失败；52 = Init 失败；53 = Start 失败；54 = 已在运行
 */
export const startAudioCapture: (onAudioFrame: AudioFrameCallback) => number;

/** 停止音频采集（幂等） */
export const stopAudioCapture: () => void;

/** 音频采集诊断快照 */
export const audioCaptureStats: () => AudioCaptureStats;
