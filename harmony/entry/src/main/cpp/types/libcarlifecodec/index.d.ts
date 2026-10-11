/**
 * CarLife 采集编码 Native 模块（libcarlifecodec.so）类型声明
 *
 * 为什么需要这一层：ArkTS 侧没有视频编码 API，屏幕采集在 ArkTS 只能录到文件。
 * 所以采集+编码在 C++ 完成，H.264 裸流通过回调回到 ArkTS，再由 ArkTS 走 TCP 发车机。
 */

/** 编码参数（来自车机 98311 下发的分辨率/帧率） */
export interface CaptureOptions {
  /** 编码宽度（px），车机下发 */
  width: number;
  /** 编码高度（px），车机下发 */
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

/** 编码器实际输出尺寸 */
export interface EncodedSize {
  width: number;
  height: number;
}

/**
 * 启动采集与编码管线。
 * 会触发系统录屏授权弹窗（系统强制，无法绕过）。
 * @returns 0 表示成功；非 0 为失败阶段号（1..9），可据此定位
 */
export const startCapture: (options: CaptureOptions, onFrame: FrameCallback, onError?: ErrorCallback) => number;

/** 停止并释放采集与编码资源 */
export const stopCapture: () => void;

/** 请求立即编码一个 I 帧 */
export const requestKeyFrame: () => void;

/** 管线是否在运行 */
export const isRunning: () => boolean;

/** 编码器实际输出尺寸（可能与请求值不同，硬件会按对齐调整） */
export const encodedSize: () => EncodedSize;
