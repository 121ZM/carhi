/**
 * CarLife 推流引擎
 *
 * 把传输层、握手状态机、采集编码串成完整链路。
 *
 * 数据流：
 *   车机 --(TCP 7240)--> 状态机握手 --> 车机确认(98313)
 *        --> NativeCodec 启动（OH_AVScreenCapture + OH_VideoEncoder）
 *        --> H.264 裸流
 *        --> packMessage(Channel2, 131073) --> 车机(8240)
 *
 * 音频不在此引擎内：导航语音通过蓝牙 A2DP 独立输出，不占用 CarLife 协议通道。
 * 触控回传明确不做（本方案只推流）。
 */

import { CarLifeChannelServer, ChannelServerListener } from '../transport/ChannelServer';
import { CarLifeStateMachine, HandshakeState, StateMachineListener, VideoParams } from './StateMachine';
import { NativeCodec } from './NativeCodec';
import { BackgroundKeeper } from './BackgroundKeeper';
import { Message, packMessage } from '../protocol/Framing';
import * as C from '../protocol/Constants';

/** 引擎状态回调 */
export interface EngineListener {
  onStateChange: (state: HandshakeState) => void;
  onLog: (text: string) => void;
  onChannelChange: (channel: number, connected: boolean) => void;
  onStats: (fps: number, kbps: number, frames: number) => void;
}

export class CarLifeEngine {
  private server: CarLifeChannelServer | null = null;
  private sm: CarLifeStateMachine | null = null;
  private codec: NativeCodec | null = null;
  private listener: EngineListener;
  private streaming: boolean = false;

  // 统计
  private frameCount: number = 0;
  private statTimer: number = -1;
  private lastFrameCount: number = 0;
  private lastBytes: number = 0;
  private totalBytes: number = 0;

  constructor(listener: EngineListener) {
    this.listener = listener;
  }

  /** 启动全部服务 */
  async start(): Promise<void> {
    this.listener.onLog('正在启动 CarLife 手机端...');

    // ---------- 1. 传输层 ----------
    const srvListener: ChannelServerListener = {
      onChannelConnected: (channel: number) => {
        this.listener.onChannelChange(channel, true);
        this.listener.onLog(`通道 ${channel} 已连接`);
        if (channel === C.CHANNEL_CMD && this.sm !== null) {
          // 控制通道建立即启动握手与心跳
          this.sm.start();
        }
        if (channel === C.CHANNEL_VIDEO && this.codec !== null) {
          // 车机刚接上视频通道，立刻补一个 I 帧，避免它等一个 GOP 才有画面
          this.codec.requestKeyFrame();
        }
      },
      onChannelDisconnected: (channel: number) => {
        this.listener.onChannelChange(channel, false);
        this.listener.onLog(`通道 ${channel} 已断开`);
        if (channel === C.CHANNEL_CMD) {
          this.stopStreaming();
          this.sm?.stop();
        }
      },
      onCommandMessage: (msg: Message) => {
        this.sm?.handleMessage(msg).catch((e: Error) => {
          this.listener.onLog(`处理消息异常: ${e.message}`);
        });
      },
      onError: (channel: number, err: string) => {
        this.listener.onLog(`通道 ${channel} 错误: ${err}`);
      }
    };

    this.server = new CarLifeChannelServer(srvListener);

    // ---------- 2. 状态机 ----------
    const smListener: StateMachineListener = {
      onStateChange: (state: HandshakeState) => {
        this.listener.onStateChange(state);
      },
      onLog: (text: string) => {
        this.listener.onLog(text);
      },
      onVideoStart: (params: VideoParams) => {
        this.startStreaming(params).catch((e: Error) => {
          this.listener.onLog(`启动推流失败: ${e.message}`);
        });
      },
      onVideoPause: () => {
        this.stopStreaming();
      },
      sendCommand: async (serviceType: number, payload: Uint8Array) => {
        if (this.server === null) {
          throw new Error('server not ready');
        }
        const frame = packMessage(C.CHANNEL_CMD, serviceType, payload);
        await this.server.send(C.CHANNEL_CMD, frame);
      }
    };

    this.sm = new CarLifeStateMachine(smListener);

    // ---------- 3. 启动监听 ----------
    await this.server.start();
    this.listener.onLog('已在 7240/8240/9240/9241/9242/9340/9440 端口监听，等待车机连接');

    // ---------- 4. 统计定时器 ----------
    this.statTimer = setInterval(() => {
      const frames = this.frameCount - this.lastFrameCount;
      const bytes = this.totalBytes - this.lastBytes;
      this.lastFrameCount = this.frameCount;
      this.lastBytes = this.totalBytes;
      this.listener.onStats(frames, Math.round(bytes * 8 / 1000), this.frameCount);
    }, 1000);
  }

  /** 启动屏幕采集与推流 */
  private async startStreaming(params: VideoParams): Promise<void> {
    if (this.streaming) {
      return;
    }

    // 后台推流需要长时任务，否则切到导航后会被系统冻结
    const kept = await BackgroundKeeper.acquire();
    if (!kept) {
      this.listener.onLog('警告: 长时任务申请失败，切到后台后推流可能被系统中断');
    }

    this.codec = new NativeCodec();
    this.codec.start(params, {
      onFrame: (nalu: Uint8Array, pts: number, keyFrame: boolean) => {
        this.onEncodedFrame(nalu, pts);
      },
      onError: (code: number, msg: string) => {
        this.listener.onLog(`[编码] 错误(${code}): ${msg}`);
        // 采集被用户/系统掐掉，推流已无意义
        this.stopStreaming();
      },
      onLog: (text: string) => {
        this.listener.onLog(text);
      }
    });

    this.streaming = true;
  }

  /** 编码产物回调：封包后发往视频通道 */
  private onEncodedFrame(nalu: Uint8Array, pts: number): void {
    const server = this.server;
    if (!this.streaming || server === null) {
      return;
    }
    if (!server.isVideoReady) {
      return;   // 视频通道未就绪，丢弃（等它连上会补 I 帧）
    }
    this.frameCount++;
    this.totalBytes += nalu.length;

    // 视频通道：12 字节头，serviceType = 131073
    const frame = packMessage(C.CHANNEL_VIDEO, C.MSG_VIDEO_DATA, nalu, pts & 0xFFFFFFFF);
    server.send(C.CHANNEL_VIDEO, frame).catch(() => {
      // 发送失败视为通道异常，'close' 事件会感知
    });
  }

  /** 停止推流 */
  private stopStreaming(): void {
    if (!this.streaming) {
      return;
    }
    this.streaming = false;
    this.codec?.stop();
    this.codec = null;
    this.listener.onLog('推流已停止');
  }

  /** 停止全部 */
  stop(): void {
    if (this.statTimer !== -1) {
      clearInterval(this.statTimer);
      this.statTimer = -1;
    }
    this.stopStreaming();
    this.sm?.stop();
    this.server?.stop();
    this.server = null;
    this.sm = null;
    BackgroundKeeper.release();
  }
}
