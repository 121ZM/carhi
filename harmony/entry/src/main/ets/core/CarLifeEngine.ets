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
import { CaptureGate, CaptureGrantState } from './CaptureGate';
import { Message, packMessage } from '../protocol/Framing';
import * as C from '../protocol/Constants';

/** 引擎状态回调 */
export interface EngineListener {
  onStateChange: (state: HandshakeState) => void;
  onLog: (text: string) => void;
  onChannelChange: (channel: number, connected: boolean) => void;
  onStats: (fps: number, kbps: number, frames: number) => void;
  /**
   * 即将弹出录屏授权框。
   * 手机端系统强制弹框且不记忆授权，因此这里只是给 UI 一个"请点允许"的提示。
   */
  onGrantPrompt: () => void;
  /**
   * 授权受阻（用户拒绝 / 尝试用尽），需要用户手动点「重新授权」。
   * @param reason 可读原因
   */
  onCaptureBlocked: (reason: string) => void;
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

  // ---- 车机视频心跳（131074，经 VIDEO 通道下发）----
  /** 最近一次收到心跳的时间戳（ms），0 表示尚未收到 */
  private lastVideoHeartbeat: number = 0;
  /** 累计收到的心跳数 */
  private videoHeartbeatCount: number = 0;
  /** 是否已就"心跳超时"告警过（避免每秒刷屏） */
  private heartbeatWarned: boolean = false;

  // ---- 采集中断自动恢复 ----
  /** 最近一次启动推流用的参数，恢复时复用 */
  private lastParams: VideoParams | null = null;
  /** 连续重试计数，成功出帧后清零 */
  private retryCount: number = 0;
  /** 重试定时器句柄 */
  private retryTimer: number = -1;
  /** 重试上限：连续失败这么多次就放弃，避免死循环骚扰系统弹窗 */
  private static readonly MAX_RETRY: number = 5;
  /** 重试间隔（毫秒）。给系统留出恢复时间（如来电结束） */
  private static readonly RETRY_DELAY_MS: number = 2000;

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
        // 车机暂停推流：停掉编码/采集即可，**不要**断开端口监听或控制通道。
        // 官方做法是 pauseFromHeadUnit()，串流可随时恢复；若在此拆掉连接，
        // 车机侧会认为手机掉线，需要重新握手。
        this.stopStreaming();
      },
      onFrameRateChange: (frameRate: number) => {
        // 只调编码器帧率，管线保持存活。失败也不影响推流（沿用原帧率）。
        const codec = this.codec;
        if (codec !== null && codec.isRunning) {
          codec.setFrameRate(frameRate);
          this.listener.onLog(`[编码] 帧率已调整为 ${frameRate}fps（管线未重启）`);
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
    await this.server.start();
    this.listener.onLog('已在 7240/8240/9240/9241/9242/9340/9440 端口监听，等待车机连接');

    // ---------- 3.5 立即申请长时任务 ----------
    // 改为「服务启动即持有」：长时任务覆盖整个应用生命周期，
    // 这样即使还没车机连接、或推流中途用户切到别的 App，
    // 监听与保活都不会被系统冻结。代价是启动后会有常驻通知（可点通知回到本应用）。
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

  /** 启动屏幕采集与推流 */
  private async startStreaming(params: VideoParams): Promise<void> {
    if (this.streaming) {
      return;
    }
    this.lastParams = params;

    // 录屏授权门控：手机端启动采集时系统**必定**弹隐私保护授权框，
    // 应用无法记忆授权。这里只在配额内主动弹（见 CaptureGate 注释），
    // 避免"车机重连 / 采集中断重试"把授权框反复弹出来骚扰用户。
    if (!CaptureGate.tryLaunch()) {
      this.listener.onLog(`[授权] ${CaptureGate.label}，已停止自动启动采集。`
        + '请点界面上的「重新授权」按钮后再试。');
      this.listener.onCaptureBlocked(CaptureGate.label);
      return;
    }
    if (CaptureGate.current !== CaptureGrantState.GRANTED) {
      this.listener.onLog('[授权] 即将弹出系统录屏授权框，请在弹框中点「允许」，否则推流无法开始');
      this.listener.onGrantPrompt();
    }

    // 长时任务已在 start() 阶段申请并持有（幂等，此处只是兜底补申请）。
    if (!BackgroundKeeper.isActive) {
      const kept = await BackgroundKeeper.acquire();
      if (!kept.ok) {
        this.listener.onLog(`警告: ${kept.reason}`);
        this.listener.onLog('提示: 切到后台后推流可能被系统中断，请保持本应用在前台或锁屏外');
      }
    }

    this.codec = new NativeCodec();
    try {
      this.codec.start(params, {
        onFrame: (nalu: Uint8Array, pts: number, keyFrame: boolean) => {
          this.retryCount = 0;   // 出帧即视为健康，清零重试计数
          CaptureGate.markGranted();   // 出帧 = 用户已允许录屏
          this.onEncodedFrame(nalu, pts);
        },
        onError: (code: number, msg: string) => {
          this.handleCodecError(code, msg);
        },
        onLog: (text: string) => {
          this.listener.onLog(text);
        }
      });
    } catch (e) {
      const err = e as Error;
      this.listener.onLog(`[编码] 启动失败: ${err.message}`);
      this.codec = null;
      // 启动失败大多是 STAGE_START_CAPTURE_FAILED（用户在授权框点了取消）。
      CaptureGate.markFailed();
      if (CaptureGate.needsUserAction) {
        this.listener.onLog(`[授权] ${CaptureGate.label} —— 已停止自动重试，`
          + '请在界面上点「重新授权」并允许录屏');
        this.listener.onCaptureBlocked(CaptureGate.label);
      }
      return;
    }

    this.streaming = true;
  }

  /**
   * 编码/采集中断的统一入口。
   *
   * 关键分支：
   *   可恢复（切后台/来电/被抢占） -> 延迟重试重建采集，不放弃整车机连接。
   *   不可恢复（用户主动取消/停止） -> 停流，避免反复弹授权框骚扰用户。
   */
  private handleCodecError(code: number, msg: string): void {
    this.listener.onLog(`[编码] 错误(${code}): ${msg}`);

    if (!NativeCodec.isRecoverable(code)) {
      this.listener.onLog('[编码] 属于用户主动停止，不再重试');
      this.stopStreaming();
      return;
    }

    // 授权受阻时绝不进入自动重试 —— 每重试一次就会再弹一次授权框，
    // 是对用户最直接的骚扰来源。此处直接停下，等用户手动恢复。
    if (CaptureGate.needsUserAction) {
      this.listener.onLog(`[授权] ${CaptureGate.label}，停止自动重试以避免反复弹框`);
      this.stopStreaming();
      this.listener.onCaptureBlocked(CaptureGate.label);
      return;
    }

    if (this.retryCount >= CarLifeEngine.MAX_RETRY) {
      this.listener.onLog(`[编码] 已连续重试 ${this.retryCount} 次仍失败，停止推流`);
      this.stopStreaming();
      return;
    }

    this.retryCount++;
    this.listener.onLog(`[编码] 检测到可恢复中断，${CarLifeEngine.RETRY_DELAY_MS / 1000}s 后重试`
      + `（第 ${this.retryCount}/${CarLifeEngine.MAX_RETRY} 次）`);
    this.scheduleRetry();
  }

  /** 安排一次采集重启 */
  private scheduleRetry(): void {
    if (this.retryTimer !== -1) {
      return;   // 已有待执行的重试，避免叠加
    }
    this.retryTimer = setTimeout(() => {
      this.retryTimer = -1;
      this.attemptRecover();
    }, CarLifeEngine.RETRY_DELAY_MS);
  }

  /** 执行恢复：优先"只重启采集"，失败再退化到"整体重启" */
  private attemptRecover(): void {
    if (!this.streaming) {
      return;
    }
    const codec = this.codec;

    // 路径 1：编码器还活着 —— 只重建采集，最快
    if (codec !== null && codec.isRunning) {
      if (codec.restartCapture()) {
        return;
      }
    }

    // 路径 2：整条管线已失效 —— 完整重启
    this.listener.onLog('[编码] 局部恢复失败，尝试重启整条采集编码管线');
    if (codec !== null) {
      codec.stop();
    }
    this.codec = null;
    const params = this.lastParams;
    if (params === null) {
      this.stopStreaming();
      return;
    }
    // 借用 streaming 标志位做一次完整重启（先复位再走标准启动流程）
    this.streaming = false;
    this.startStreaming(params).catch((e: Error) => {
      this.listener.onLog(`[编码] 重启异常: ${e.message}`);
      this.stopStreaming();
    });
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
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    this.retryCount = 0;
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

  /**
   * 用户手动「重新授权」：清空授权门控配额后重新启动采集。
   * 会再次弹出系统录屏授权框 —— 这是唯一一次由用户主动触发的弹框。
   */
  retryCapture(): void {
    CaptureGate.reset();
    this.listener.onLog('[授权] 已重置授权状态，即将重新弹出录屏授权框，请点「允许」');
    const params = this.lastParams;
    if (params === null) {
      this.listener.onLog('[授权] 尚无车机下发的视频参数，请等车机连接后再试');
      return;
    }
    if (this.streaming) {
      // 采集仍在跑，无需重启
      this.listener.onLog('[授权] 采集运行中，无需重新授权');
      return;
    }
    this.startStreaming(params).catch((e: Error) => {
      this.listener.onLog(`[授权] 重启采集异常: ${e.message}`);
    });
  }
}
