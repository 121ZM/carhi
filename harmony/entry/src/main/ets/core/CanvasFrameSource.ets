/**
 * 自绘画布画面来源（路线 A）
 *
 * ## 角色
 *
 * 把「ArkTS 画的界面」变成「车机能收的 H.264 流」：
 *
 *   ArkTS 界面（XComponent 渲染）
 *        │  同一个 surfaceId
 *        ▼
 *   native 编码器（libcarlifecodec）──▶ H.264 裸流 ──▶ CarLifeEngine ──▶ 车机 8240
 *
 * ## 为什么走 XComponent（A2 方案）
 *
 * 官方 CarLife 是 Native GL 自绘，但那是为了极致性能 + 当时的选择。
 * 我们要做的是「导航 + 音频」这类界面，用 ArkTS 写效率高一个数量级
 * （系统字体、图片、布局、动画全都能直接用）。代价是依赖 XComponent 的
 * surface 能被编码器直接消费 —— 这正是本模块要验证并落实的。
 *
 * ## 关键约束
 *
 * XComponent 的 surfaceId 只在组件 `onLoad` 之后才有效。
 * 所以启动顺序必须是：
 *   1. 页面渲染出 XComponent
 *   2. XComponent onLoad 回调里拿到 surfaceId
 *   3. 把 surfaceId 交给本模块 → 启动 native 编码器
 * 若编码器先于画布就绪，用 `attachSurface()` 补绑。
 */

import { FrameSource } from './CarLifeEngine';
import { VideoParams } from './StateMachine';
import { CarLifeRuntime } from '../entryability/EntryAbility';
import carlifecodec from 'libcarlifecodec.so';

/** 画面编码参数（由车机下发的 VideoParams 换算而来） */
interface EncoderOptions {
  width: number;
  height: number;
  frameRate: number;
  bitrate: number;
  iFrameIntervalMs?: number;
}

export class CanvasFrameSource implements FrameSource {
  /**
   * 画布 Surface id（来自 XComponent.onLoad）。
   *
   * 注意是 **string**：ArkTS 的 XComponent 返回的是字符串形式的 id，
   * 可能超出 double 的精度范围，所以全程按字符串传递，native 侧按
   * bigint/string 解析（见 napi_init.cpp 的 GetSurfaceId）。
   */
  private surfaceId: string = '';
  private running: boolean = false;
  private params: VideoParams | null = null;
  private onFrameCb: ((nalu: Uint8Array, pts: number, keyFrame: boolean) => void) | null = null;
  /**
   * 画布的实际像素尺寸（由页面从 XComponent 上报）。
   *
   * ★ 为什么必须要有这个（2026-10-13 实测教训）：
   *   编码器配置的宽高**必须等于画布 surface 的真实尺寸**，否则编码器
   *   收不到有效输入帧（录屏方案里就因此出过 code=10、一帧编不出来、
   *   把车机搞崩）。车机下发的 1280×720 是"它期望的分辨率"，不一定
   *   等于我们这块画布的实际像素。所以以画布实测尺寸为准。
   */
  private canvasW: number = 0;
  private canvasH: number = 0;

  /** 由页面在 XComponent 的 onLoad / onAreaChange 回调里调用 */
  setSurfaceId(id: string): void {
    this.surfaceId = id;
    CarLifeRuntime.addLog(`[画布] 已取得 surfaceId（${id.length > 12 ? id.slice(0, 12) + '...' : id}）`);
    // 若编码器已在跑但之前没画布，这里补绑
    if (this.running) {
      const stage: number = carlifecodec.attachSurface(id);
      CarLifeRuntime.addLog(stage === 0 ? '[画布] 已补绑到编码器' : `[画布] ⚠ 补绑失败(stage=${stage})`);
    }
  }

  /** 上报画布实际像素尺寸（XComponent 的布局尺寸） */
  setCanvasSize(w: number, h: number): void {
    if (w <= 0 || h <= 0) {
      return;
    }
    if (this.canvasW === w && this.canvasH === h) {
      return;
    }
    this.canvasW = w;
    this.canvasH = h;
    CarLifeRuntime.addLog(`[画布] 画布实际尺寸 ${w}x${h}`);
  }

  get hasSurface(): boolean {
    return this.surfaceId !== '';
  }

  get isRunning(): boolean {
    return this.running;
  }

  start(params: VideoParams,
        onFrame: (nalu: Uint8Array, pts: number, keyFrame: boolean) => void,
        onError: (code: number, msg: string) => void): boolean {
    if (this.running) {
      return true;
    }
    this.params = params;
    this.onFrameCb = onFrame;

    // ★ 编码尺寸以**画布实际像素**为准（若已上报），否则退回车机下发值。
    //   两者不一致会让编码器配置失败或收不到有效输入帧 —— 录屏方案踩过这个坑。
    let useW: number = this.canvasW > 0 ? this.canvasW : params.width;
    let useH: number = this.canvasH > 0 ? this.canvasH : params.height;
    // 编码器要求宽高为**偶数**（YUV 4:2:0 色度采样按 2×2 处理），
    // 奇数尺寸会在 Configure 阶段直接失败。宁可差 1px 也不能让它挂。
    useW = useW - (useW % 2);
    useH = useH - (useH % 2);
    if (useW < 128 || useH < 128) {
      // 画布太小（布局异常）—— 回退到车机下发值，至少能把链路跑起来
      CarLifeRuntime.addLog(`[画布] ⚠ 画布像素过小(${useW}x${useH})，回退 ${params.width}x${params.height}`);
      useW = params.width;
      useH = params.height;
    }

    const opts: EncoderOptions = {
      width: useW,
      height: useH,
      frameRate: params.frameRate,
      // 码率按像素数估算：约 0.15 bit/px/frame，下限 1.5Mbps 上限 12Mbps。
      // 为什么不做成固定值：车机可能是 1280×720 也可能是 1920×720，
      // 固定码率在低分辨率下浪费、高分辨率下糊。
      bitrate: CanvasFrameSource.bitrateFor(useW, useH, params.frameRate),
      iFrameIntervalMs: 2000
    };

    const stage: number = carlifecodec.startEncoder(
      this.surfaceId === '' ? '0' : this.surfaceId,
      opts,
      (data: ArrayBuffer, pts: number, keyFrame: boolean) => {
        const cb = this.onFrameCb;
        if (cb !== null) {
          cb(new Uint8Array(data), pts, keyFrame);
        }
      },
      (code: number, msg: string) => {
        onError(code, msg);
      });

    if (stage !== 0) {
      CarLifeRuntime.addLog(`[画布] ✗ 编码器启动失败 stage=${stage}`);
      this.onFrameCb = null;
      return false;
    }

    this.running = true;
    if (this.surfaceId === '') {
      // 编码器起来了但还没画布：能建管线、暂时不产帧，等 setSurfaceId 补绑。
      CarLifeRuntime.addLog('[画布] 编码器已就绪，等待画布 surfaceId（XComponent onLoad）');
    } else {
      CarLifeRuntime.addLog(`[画布] 编码器已启动并绑定画布（${params.width}x${params.height}`
        + ` @ ${params.frameRate}fps, ${Math.round(opts.bitrate / 1000)}kbps）`);
    }
    return true;
  }

  stop(): void {
    if (!this.running) {
      return;
    }
    this.running = false;
    this.onFrameCb = null;
    try {
      carlifecodec.stopEncoder();
      CarLifeRuntime.addLog('[画布] 编码器已停止');
    } catch (e) {
      const err = e as Error;
      CarLifeRuntime.addLog(`[画布] 停止异常: ${err.message}`);
    }
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
      CarLifeRuntime.addLog(`[画布] ⚠ 帧率调整失败（ret=${ret}），沿用原帧率`);
    }
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
