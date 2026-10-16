/**
 * CarLife 引擎（路线 A：自绘画面，不走录屏）
 *
 * 把传输层、握手状态机串成完整链路。
 *
 * 数据流：
 *   车机 --(TCP 7240)--> 状态机握手 --> 车机确认(98313) 开始推流
 *        --> <画面来源> H.264 裸流
 *        --> packMessage(Channel2, 131073) --> 车机(8240)
 *
 * ★ 2026-10-13 方向性重置：**彻底废弃录屏镜像方案**。
 *   官方 CarLife 手机端不走录屏 —— 它自己写导航页面、自己渲染，把渲染结果
 *   直接编码推给车机。录屏方案自带的四个死结（切后台中断采集、息屏中断、
 *   横屏 VirtualDisplay 尺寸不匹配、每次都要用户点录屏授权）在官方方案里
 *   全都不存在。已删除：NativeCodec / CaptureGate / KeepScreen /
 *   ScreenSizeProbe / PipProbe / screen_encoder.cpp。
 *
 *   本文件现在只负责：协议握手 + 通道收发 + 心跳 + 统计 + 把「画面来源」
 *   产出的 H.264 帧封包发往视频通道。**画面从哪里来由 route A 的画布层决定**
 *   （待接入：自绘 Surface -> 编码器）。
 *
 * 音频不在此引擎内：导航语音通过蓝牙 A2DP 独立输出，不占用 CarLife 协议通道。
 */

import { CarLifeChannelServer, ChannelServerListener } from '../transport/ChannelServer';
import { CarLifeStateMachine, HandshakeState, StateMachineListener, VideoParams } from './StateMachine';
import { BackgroundKeeper } from './BackgroundKeeper';
import { Message, packMessage } from '../protocol/Framing';
import { CarlifeTouchAction } from '../protocol/Messages';
import * as C from '../protocol/Constants';

/** 引擎状态回调 */
export interface EngineListener {
  onStateChange: (state: HandshakeState) => void;
  onLog: (text: string) => void;
  onChannelChange: (channel: number, connected: boolean) => void;
  onStats: (fps: number, kbps: number, frames: number) => void;
}

/**
 * 画面来源（视频帧生产者）的约定接口。
 *
 * 路线 A 里，画面由「自绘画布 + 编码器」产出。引擎不关心它是怎么画的、
 * 用 GL 还是 ArkTS，只要求它按这个接口交付 H.264 裸流。这样引擎与
 * 画面层解耦，将来换实现（GL 自绘 / XComponent / 别的）不用动引擎。
 */
export interface FrameSource {
  /** 启动画面产出（成功返回 true） */
  start(params: VideoParams, onFrame: (nalu: Uint8Array, pts: number, keyFrame: boolean) => void,
        onError: (code: number, msg: string) => void): boolean;
  /** 停止并释放资源（幂等） */
  stop(): void;
  /** 请求立刻产出一个 I 帧（车机刚连上时用） */
  requestKeyFrame(): void;
  /** 动态调整帧率（车机下发 98316 时调用） */
  setFrameRate(frameRate: number): void;
  /** 是否正在产出画面 */
  readonly isRunning: boolean;
}

/**
 * 画面来源工厂。
 *
 * 目前**未接入实现** —— 路线 A 的画布层还没写（这是下一步工作）。
 * 在它落地之前，引擎会把「已收到车机启动指令、准备推流」这一步走到位，
 * 但不产出任何画面帧；UI 上会明确提示这一点，避免误以为在推流。
 *
 * 接入时只需在这里返回一个实现了 FrameSource 的对象即可。
 */
export type FrameSourceFactory = () => FrameSource;

export class CarLifeEngine {
  private server: CarLifeChannelServer | null = null;
  private sm: CarLifeStateMachine | null = null;
  private source: FrameSource | null = null;
  private listener: EngineListener;
  private frameSourceFactory: FrameSourceFactory | null = null;
  private streaming: boolean = false;

  // 统计
  private frameCount: number = 0;
  private statTimer: number = -1;
  private lastFrameCount: number = 0;
  private lastBytes: number = 0;
  private totalBytes: number = 0;

  // ---- 车机视频心跳（131074，经 VIDEO 通道下发）----
  /** 最近一次收到心跳的时间戳（ms），0 表示尚未收到 */
  private lastVideoHeartbeat: number = 0;
  /** 累计收到的心跳数 */
  private videoHeartbeatCount: number = 0;
  /** 是否已就"心跳超时"告警过（避免每秒刷屏） */
  private heartbeatWarned: boolean = false;

  /** 最近一次启动推流用的参数 */
  private lastParams: VideoParams | null = null;

  constructor(listener: EngineListener, factory: FrameSourceFactory | null = null) {
    this.listener = listener;
    this.frameSourceFactory = factory;
  }

  /**
   * 注册/更换画面来源工厂（幂等）。
   * 供 UI 层在拿到画布（如 XComponent 的 surfaceId）之后再接上编码器。
   */
  setFrameSourceFactory(factory: FrameSourceFactory | null): void {
    this.frameSourceFactory = factory;
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
        if (channel === C.CHANNEL_VIDEO && this.source !== null) {
          // 车机刚接上视频通道，立刻补一个 I 帧，避免它等一个 GOP 才有画面
          this.source.requestKeyFrame();
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
      onVideoMessage: (msg: Message) => {
        // 视频通道的入站数据几乎只有车机心跳 131074。
        // 先记录所有到达的包（含未知 ID），便于确认车机到底在发什么。
        if (msg.serviceType === C.MSG_CMD_HU_HEARTBEAT) {
          this.lastVideoHeartbeat = Date.now();
          this.videoHeartbeatCount++;
          // 心跳很频繁，不做逐条日志，只在首个与每 20 个打一次，避免刷屏
          if (this.videoHeartbeatCount <= 3 || this.videoHeartbeatCount % 20 === 0) {
            this.listener.onLog(`[心跳] 收到车机视频心跳 ×${this.videoHeartbeatCount}`);
          }
        } else {
          this.listener.onLog(`[视频通道] 收到车机消息 ID=${msg.serviceType} len=${msg.payload.length}`);
        }
      },
      onOtherMessage: (channel: number, msg: Message) => {
        // ★ AUDIO/TTS/VR/TOUCH/DATA 的入站数据。此前 ChannelServer 里没有分支，
        //   这些包**读进来就被丢掉** —— 其中 TOUCH(9340, Ch6) 是车机→手机的
        //   触控通道（CarlifeTouchAction 425985 等）。
        //
        //   ★ 路线 A 的重大变化：自绘方案里，触控**终于有用了**！
        //     官方就是这么做的：车机把点击坐标发过来，手机端用它来操作自己画的 UI
        //     （点导航按钮、拖地图）。**不需要系统级输入注入权限** —— 因为那个 UI
        //     是我们自己画的，直接改自己的状态就行。
        //     这就是为什么官方能"点得动"而录屏方案点不动。
        if (channel === C.CHANNEL_TOUCH && msg.serviceType === C.MSG_TOUCH_ACTION) {
          const t: CarlifeTouchAction = CarlifeTouchAction.decode(msg.payload);
          this.listener.onLog(`[触控] ← TOUCH_ACTION action=${t.action}`
            + ` x=${t.x} y=${t.y} pointer=(${t.pointerx},${t.pointery})`);
          // TODO(route A)：把触控坐标投给自绘画布，驱动导航/控件的交互。
          return;
        }
        let hex: string = '';
        const n: number = Math.min(16, msg.payload.length);
        for (let i = 0; i < n; i++) {
          hex += msg.payload[i].toString(16).padStart(2, '0');
          if (i !== n - 1) {
            hex += ' ';
          }
        }
        this.listener.onLog(`[通道${channel}] ← ${C.msgName(msg.serviceType)}`
          + ` (ID=${msg.serviceType}, len=${msg.payload.length})`
          + (hex !== '' ? ` hex=${hex}` : ''));
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
        this.startStreaming(params);
      },
      onVideoPause: () => {
        // 车机暂停推流：停掉画面产出即可，**不要**断开端口监听或控制通道。
        // 官方做法是 pauseFromHeadUnit()，串流可随时恢复；若在此拆掉连接，
        // 车机侧会认为手机掉线，需要重新握手。
        this.stopStreaming();
      },
      onFrameRateChange: (frameRate: number) => {
        // 只调帧率，画面管线保持存活。失败也不影响推流（沿用原帧率）。
        const src = this.source;
        if (src !== null && src.isRunning) {
          src.setFrameRate(frameRate);
          this.listener.onLog(`[画面] 帧率已调整为 ${frameRate}fps（管线未重启）`);
        }
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
    // ⚠ 这里**必须按真实结果**说话。
    //   `server.start()` 内部是逐端口 try/catch —— 某个端口绑失败**不会抛出来**。
    //   原来无条件打印「已在 ... 端口监听」，于是 7 个端口全部绑定失败时
    //   界面照样显示「已监听」，是个会骗人的假通过（2026-10-13 排查时踩到）。
    await this.server.start();
    const listenRes: string[] = this.server.listenResults;
    const okPorts: number = this.server.listeningCount;
    if (listenRes.length > 0 && okPorts === listenRes.length) {
      this.listener.onLog('已在 7240/8240/9240/9241/9242/9340/9440 端口监听，等待车机连接');
    } else {
      this.listener.onLog(`⚠ 端口监听不完整（${okPorts}/${listenRes.length}）：${listenRes.join('  ')}`);
    }

    // ---------- 3.5 立即申请长时任务 ----------
    // 服务启动即持有：长时任务覆盖整个应用生命周期，这样即使还没车机连接、
    // 或推流中途用户切到别的 App，监听与保活都不会被系统冻结。
    // 代价是启动后会有常驻通知（可点通知回到本应用）。
    const kept = await BackgroundKeeper.acquire();
    if (kept.ok) {
      this.listener.onLog(`长时任务已生效（${kept.mode}）`);
    } else {
      this.listener.onLog(`警告: ${kept.reason}`);
      this.listener.onLog('提示: 未持有长时任务，切到后台可能被系统冻结');
    }

    // ---------- 4. 统计定时器 ----------
    this.statTimer = setInterval(() => {
      const frames = this.frameCount - this.lastFrameCount;
      const bytes = this.totalBytes - this.lastBytes;
      this.lastFrameCount = this.frameCount;
      this.lastBytes = this.totalBytes;
      this.listener.onStats(frames, Math.round(bytes * 8 / 1000), this.frameCount);

      // 心跳健康度：超过 3 秒没收到车机视频心跳就要警惕（车机侧阈值约 6 秒）。
      // 注意只在"正常 → 异常"的那一次转换时告警，否则会每秒刷屏。
      const now = Date.now();
      const silent = this.lastVideoHeartbeat !== 0 && now - this.lastVideoHeartbeat > 3000;
      if (silent && !this.heartbeatWarned) {
        this.heartbeatWarned = true;
        this.listener.onLog(`[心跳] ⚠ 已 ${Math.round((now - this.lastVideoHeartbeat) / 1000)}s`
          + ` 未收到车机视频心跳（累计 ${this.videoHeartbeatCount} 次）`);
      } else if (!silent) {
        this.heartbeatWarned = false;   // 恢复后允许下次再报
      }
    }, 1000);
  }

  /**
   * 启动画面产出与推流。
   *
   * ★ 与录屏方案的区别：这里**没有录屏授权、没有常亮、没有采集中断恢复**。
   *   画面来源是我们自己渲染的，不受系统采集管线约束，切后台/息屏/旋转
   *   都不会打断它（前提：长时任务保持）。
   */
  private startStreaming(params: VideoParams): void {
    if (this.streaming) {
      return;
    }
    this.lastParams = params;

    const factory = this.frameSourceFactory;
    if (factory === null) {
      // 画布层尚未接入（路线 A 的下一步工作）。明确说出来，不要让 UI 误以为在推流。
      this.listener.onLog('⚠ 画面来源尚未接入：协议已就绪，但暂不会产生画面。'
        + '（路线 A 的自绘画布层待实现）');
      return;
    }

    const src = factory();
    if (!src.start(params,
      (nalu: Uint8Array, pts: number, keyFrame: boolean) => {
        this.onEncodedFrame(nalu, pts);
      },
      (code: number, msg: string) => {
        // ★ 第二道防线（2026-10-15 真机两次踩坑，两条都兜住）：
        //   1) code === 0 不是错误（AV_ERR_OK），编码器正常出帧时可能回调 onError(0)；
        //   2) code 若不是 number（真机实测出现过 ArrayBuffer），说明帧回调被错绑到
        //      错误回调上了（CallFrameJs 的 (ArrayBuffer, pts) 两个参数串进来），
        //      这时收到的其实是**正常的编码帧**，更不能拆管线。
        //   任何一条命中都只记日志、不 stopStreaming —— 拆管线 = 车机黑屏。
        if (typeof code !== 'number') {
          this.listener.onLog(`[画面] 忽略非数字错误码（疑似帧回调错绑）: ${typeof code}`);
          return;
        }
        if (code === 0) {
          return;
        }
        this.listener.onLog(`[画面] 错误(${code}): ${msg}`);
        this.stopStreaming();
      })) {
      this.listener.onLog('[画面] 启动失败');
      return;
    }

    this.source = src;
    this.streaming = true;
    this.listener.onLog(`[画面] 已开始产出（${params.width}x${params.height} @ ${params.frameRate}fps）`);
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
    this.source?.stop();
    this.source = null;
    this.listener.onLog('推流已停止');
  }

  /**
   * ★ 运行时切换画面源（自绘 ⇄ 应用投屏）。
   *
   * 用于「应用投屏」开关：工厂 `frameSourceFactory()` 会返回当前生效的源，
   * 所以这里**先停掉现有画面管线、再按同一套参数重启** —— 新源即可接管。
   *
   * ★ 为什么要"停掉再重启"而不是热替换：
   *   两种源都独占硬件编码器（`startHmi` 与 `startCapture` 是两套编码器实例），
   *   同时存在会互相抢资源。走一次完整的 stop→start 最稳。
   *
   * @returns true = 已切换（或当前无车机连接、无管线可切）
   */
  switchFrameSource(): boolean {
    const params = this.lastParams;
    if (params === null) {
      // 车机还没下发过启动指令 —— 没有管线在跑，无需切换。
      // 下次车机启动推流时，工厂会自然取到新的源。
      this.listener.onLog('[画面源] 暂无推流管线（车机未连接），切换将在下次启动时生效');
      return false;
    }
    this.listener.onLog('[画面源] 正在切换画面源（停旧管线 → 按原参数重启）…');
    this.stopStreaming();
    // 稍等一拍再起，给编码器/采集器释放资源的时间（避免抢占）
    setTimeout(() => {
      this.startStreaming(params);
    }, 300);
    return true;
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
