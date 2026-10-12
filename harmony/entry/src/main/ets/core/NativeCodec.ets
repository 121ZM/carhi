/**
 * 采集编码的 ArkTS 封装（桥接到 Native 模块 libcarlifecodec.so）
 *
 * 为什么必须有这一层：
 *   1. ArkTS 侧**没有**视频编码 API —— 视频编码只在 Native 层
 *      （multimedia/player_framework/native_avcodec_videoencoder.h）
 *   2. ArkTS 的 media.createAVScreenCaptureRecorder() 是"录屏到文件"，
 *      配置里 fd 是必填项，拿不到实时帧
 *   所以"采集 -> 编码 -> 拿 H.264 裸流"整条链路在 C++ 里完成，
 *   这里只负责：把车机下发的参数传下去、把裸流接上来。
 *
 * 输出：H.264 Annex-B 裸流（含 SPS/PPS），直接可塞进 CarLife 视频通道。
 */

// 用具名导入而非默认导入：默认导入在 ArkTS 严格模式下会被推断为 any
// （触发 arkts-no-any-unknown），具名导入能拿到 index.d.ts 里的精确类型。
import {
  startCapture,
  stopCapture,
  requestKeyFrame as nativeRequestKeyFrame,
  setFrameRate as nativeSetFrameRate,
  restartCapture as nativeRestartCapture,
  isRecoverable as nativeIsRecoverable,
  encodedSize,
  CaptureOptions,
  EncodedSize
} from 'libcarlifecodec.so';
import { VideoParams } from './StateMachine';

/** 编码输出回调 */
export interface CodecListener {
  /** @param nalu H.264 裸流（Annex-B） @param pts 微秒 @param keyFrame 是否关键帧 */
  onFrame: (nalu: Uint8Array, pts: number, keyFrame: boolean) => void;
  onError: (code: number, msg: string) => void;
  onLog: (text: string) => void;
}

/** 每像素每帧的比特数经验值，用于按分辨率估算码率 */
const BITS_PER_PIXEL: number = 0.1;
/** I 帧间隔（毫秒）。2 秒一个 I 帧：车机中途重连时等待时间可接受 */
const I_FRAME_INTERVAL_MS: number = 2000;

/** Native 启动失败阶段号 -> 可读描述（与 screen_encoder.cpp 的 StartStage 一一对应） */
function stageName(stage: number): string {
  switch (stage) {
    case 1: return '创建编码器失败';
    case 2: return '配置编码器失败';
    case 3: return '获取编码器 Surface 失败';
    case 4: return '注册编码器回调失败';
    case 5: return '编码器 Prepare 失败';
    case 6: return '编码器 Start 失败';
    case 7: return '创建屏幕采集失败';
    case 8: return '屏幕采集 Init 失败';
    case 9: return '启动屏幕采集失败（多为用户拒绝录屏授权）';
    default: return `未知阶段(${stage})`;
  }
}

export class NativeCodec {
  private running: boolean = false;
  private listener: CodecListener | null = null;

  /** 按分辨率/帧率估算码率（bit/s） */
  static estimateBitrate(params: VideoParams): number {
    const raw: number = params.width * params.height * params.frameRate * BITS_PER_PIXEL;
    // 夹在 1.5Mbps ~ 20Mbps：太低画质糊，太高老车机解不动
    return Math.round(Math.min(Math.max(raw, 1500000), 20000000));
  }

  /**
   * 启动采集与编码。
   * 会触发系统录屏授权弹窗 —— 这是系统强制行为，应用无法绕过。
   */
  start(params: VideoParams, listener: CodecListener): void {
    if (this.running) {
      listener.onLog('[编码] 已在运行，忽略重复启动');
      return;
    }
    this.listener = listener;

    const bitrate: number = NativeCodec.estimateBitrate(params);
    listener.onLog(`[编码] 启动: ${params.width}x${params.height}@${params.frameRate}fps`
      + `, 码率 ${Math.round(bitrate / 1000)}kbps, Profile=Baseline, 低延迟开启`);

    const options: CaptureOptions = {
      width: params.width,
      height: params.height,
      frameRate: params.frameRate,
      bitrate: bitrate,
      iFrameIntervalMs: I_FRAME_INTERVAL_MS
    };
    const stage: number = startCapture(
      options,
      (data: ArrayBuffer, pts: number, keyFrame: boolean) => {
        const cb = this.listener;
        if (cb !== null) {
          cb.onFrame(new Uint8Array(data), pts, keyFrame);
        }
      },
      (code: number, msg: string) => {
        const cb = this.listener;
        if (cb !== null) {
          cb.onError(code, msg);
        }
      }
    );

    if (stage !== 0) {
      this.listener = null;
      throw new Error(`采集编码启动失败: ${stageName(stage)}`);
    }

    this.running = true;
    const size: EncodedSize = encodedSize();
    listener.onLog(`[编码] 管线就绪，编码器实际输出 ${size.width}x${size.height}`);
  }

  /** 请求立即编一个 I 帧（车机刚接入时用，避免等一个 GOP） */
  requestKeyFrame(): void {
    if (this.running) {
      nativeRequestKeyFrame();
    }
  }

  /**
   * 动态调整编码帧率（车机 98316）。
   * 走编码器软刷新，不重建管线 —— 保持车机侧连接与画面连续性。
   * @returns true 表示调整成功
   */
  setFrameRate(frameRate: number): boolean {
    if (!this.running || frameRate <= 0) {
      return false;
    }
    const ret: number = nativeSetFrameRate(frameRate);
    if (ret !== 0) {
      this.listener?.onLog(`[编码] 帧率调整失败(${ret})，沿用原帧率`);
      return false;
    }
    return true;
  }

  /**
   * 仅重启屏幕采集（编码器保持存活）。
   * 用于"可恢复中断"后的快速恢复，比整体 stop/start 更快、画面更稳。
   * @returns true 表示恢复成功
   */
  restartCapture(): boolean {
    if (!this.running) {
      return false;
    }
    const stage: number = nativeRestartCapture();
    if (stage === 0) {
      this.listener?.onLog('[编码] 采集已自动恢复');
      return true;
    }
    this.listener?.onLog(`[编码] 采集恢复失败: ${stageName(stage)}`);
    return false;
  }

  /** 判定错误码是否值得重试（false = 用户主动停止，别重试） */
  static isRecoverable(code: number): boolean {
    return nativeIsRecoverable(code);
  }

  get isRunning(): boolean {
    return this.running;
  }

  /** 停止并释放 */
  stop(): void {
    if (!this.running) {
      return;
    }
    this.running = false;
    stopCapture();
    if (this.listener !== null) {
      this.listener.onLog('[编码] 采集编码已停止');
    }
    this.listener = null;
  }
}
