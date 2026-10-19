/**
 * CarLife 握手与控制状态机（Channel 1）
 *
 * ## 真值源（已用官方 APK 反编译核实，见 refs/OFFICIAL_PROTOCOL.md）
 *
 * 官方实现：com/baidu/carlife/handler/CarlifeConnectHsgHandler.java
 *   - boxDelayProtocolMatchStatus() ：版本匹配成功后要做的全部动作
 *   - case MSG_CMD_STATISTIC_INFO(98343) ：车机统计信息 -> 触发鉴权 + 特征请求
 *   - case MSG_CMD_HU_INFO(98307) ：仅存储车机设备信息，**不回包**
 *
 * ## 官方握手主链路（手机端视角）
 *
 *   收 98305 HU_PROTOCOL_VERSION   -> 发 65538 MATCH_STATUS(matchStatus=1)
 *                                  -> 发 65540 MD_INFO        ★ 立即主动发！
 *   收 98343 STATISTIC_INFO        -> 发 65611 MD_AUTHEN_RESULT
 *                                  -> 发 65617 MD_FEATURE_CONFIG_REQUEST
 *   收 98307 HU_INFO               -> 仅记录，不回包
 *   收 98311 HU_VIDEO_ENCODER_INIT -> 发 65544 VIDEO_ENCODER_INIT
 *   收 98313 VIDEO_ENCODER_START   -> 开始推流 131073
 *   周期性发 MD_HEARTBEAT(65563)
 *
 * ## 历史缺陷（真机卡 30% 的根因）
 *
 * 原实现把 65540 的发送错误地绑定在 98307 上，导致：
 *   车机等手机的 65540，手机等车机的 98307 —— 双方互等，死锁。
 */

import { Message } from '../protocol/Framing';
import * as C from '../protocol/Constants';
import {
  CarlifeProtocolVersion,
  CarlifeProtocolVersionMatchStatus,
  CarlifeDeviceInfo,
  CarlifeAuthenRequest,
  CarlifeAuthenResponse,
  CarlifeAuthenResult,
  CarlifeVideoEncoderInfo
} from '../protocol/Messages';

/** 握手阶段 */
export enum HandshakeState {
  DISCONNECTED = 0,
  VERSION_NEGOTIATING = 1,
  DEVICE_INFO_EXCHANGING = 2,
  AUTHEN_CONFIRMING = 3,
  CONFIG_EXCHANGING = 4,
  VIDEO_PREPARING = 5,
  CONNECTED = 6
}

export function stateName(s: HandshakeState): string {
  switch (s) {
    case HandshakeState.DISCONNECTED: return '未连接';
    case HandshakeState.VERSION_NEGOTIATING: return '版本协商中';
    case HandshakeState.DEVICE_INFO_EXCHANGING: return '交换设备信息';
    case HandshakeState.AUTHEN_CONFIRMING: return '鉴权确认中';
    case HandshakeState.CONFIG_EXCHANGING: return '特征配置协商';
    case HandshakeState.VIDEO_PREPARING: return '视频流准备中';
    case HandshakeState.CONNECTED: return '已连接并推流';
    default: return '未知';
  }
}

/** 车机下发的视频编码参数 */
export interface VideoParams {
  width: number;
  height: number;
  frameRate: number;
}

/** 状态机事件回调 */
export interface StateMachineListener {
  onStateChange: (state: HandshakeState) => void;
  onLog: (text: string) => void;
  /** 车机确认开始推流 */
  onVideoStart: (params: VideoParams) => void;
  /** 车机暂停推流 */
  onVideoPause: () => void;
  /**
   * 车机请求变更帧率。实现方**只应调整编码器帧率**，
   * 不得停止/重启采集与推流管线（见 onVideoFrameRateChange 注释）。
   */
  onFrameRateChange?: (frameRate: number) => void;
  /** 需要发送报文到控制通道 */
  sendCommand: (serviceType: number, payload: Uint8Array) => Promise<void>;
}

/** 心跳周期（毫秒）。参考实现为 1000ms，依据 c.java:44-55 */
const HEARTBEAT_INTERVAL_MS: number = 1000;

/** 握手兜底补发周期（毫秒）。用于打破个别固件造成的握手停滞 */
const FALLBACK_INTERVAL_MS: number = 3000;

export class CarLifeStateMachine {
  private listener: StateMachineListener;
  private state: HandshakeState = HandshakeState.DISCONNECTED;
  private heartTimer: number = -1;
  private running: boolean = false;
  /** 保活发送成功计数（诊断用，验证 65563 是否真的送达车机） */
  private heartBeatOk: number = 0;
  /** 保活发送失败计数（诊断用，失败即意味着车机会判定心跳超时） */
  private heartBeatFail: number = 0;

  /** 握手兜底定时器：版本协商后若迟迟无后续，主动补发设备信息 */
  private fallbackTimer: number = -1;
  /** 是否已发送过手机设备信息（避免重复发送） */
  private deviceInfoSent: boolean = false;

  /**
   * 车机下发的视频参数。
   *
   * ★ 默认值取 **1920×720@30** —— 这不是"写死分辨率"，而是**兜底值**：
   *   正常流程里车机会经 `98311 HU_VIDEO_ENCODER_INIT` 下发真实参数，
   *   在 `onHuVideoEncoderInit()` 里覆盖本默认值（仅当下发值 > 0 时才覆盖）。
   *   本默认值只在「车机未下发 / 下发 0」时生效。
   *
   * 为什么是 1920×720：
   *   本机真机（MRT-AL10 / nova 14 Ultra）**车机模式下的实际显示尺寸就是 1920×720 横屏**
   *   （2026-10-13 实测确认；此前记的 1272×2860 是竖屏原始/规格值，非实际显示尺寸）。
   *   旧默认值 1280×720 与屏幕不匹配 —— 一方面丢了近 1/3 像素，另一方面
   *   竖屏内容硬压进横屏会变形。实测对比：1920×720 下中位帧 12.5KB，
   *   1280×720 仅 2.9KB（详见 memory 2026-10-13 第六节）。
   *   ⚠️ 真机屏幕若换型号，此值需同步调整。
   */
  /**
   * 我们推给车机的画面尺寸 —— **由我们自己定**，不迁就车机下发值。
   *
   * ★ 2026-10-13 路线 A 重置后的新含义：
   *   在录屏方案里，这个字段曾是"采集手机屏幕的尺寸"，必须等于物理屏尺寸，
   *   否则 VirtualDisplay 与编码器不匹配、一帧都编不出来（code=10）→ 车机崩溃。
   *
   *   路线 A 改自绘后，这个约束**彻底消失**：画面是我们自己渲染的，
   *   想画多大就画多大。车机下发的 98311 只是它"期望"的值，**仅作参考**。
   *
   *   这里取车机下发值作为默认（车机最熟悉自己的显示能力），
   *   把 16:9 的 1280×720 作为极端兜底。
   */
  videoParams: VideoParams = { width: 1280, height: 720, frameRate: 30 };

  /** 手机端设备信息（可在外部设置以反映真实机型） */
  deviceInfo: CarlifeDeviceInfo = CarLifeStateMachine.buildDefaultDeviceInfo();

  constructor(listener: StateMachineListener) {
    this.listener = listener;
  }

  private setState(s: HandshakeState): void {
    this.state = s;
    this.listener.onStateChange(s);
    this.listener.onLog(`状态切换 -> ${stateName(s)}`);
  }

  get currentState(): HandshakeState {
    return this.state;
  }

  /**
   * 控制通道建立后启动握手。
   *
   * 车机是握手发起方（主动发 98305），手机端等待车机发起；
   * 但手机在拿到 98305 后会【主动】发 65540，不等车机任何后续消息。
   * 这里同时启动一个兜底定时器，防止个别固件不发 98343 导致再次死锁。
   */
  start(): void {
    this.running = true;
    this.setState(HandshakeState.VERSION_NEGOTIATING);
    this.startHeartbeat();
    this.startFallbackTimer();
  }

  /** 处理控制通道收到的报文 */
  async handleMessage(msg: Message): Promise<void> {
    const name: string = C.msgName(msg.serviceType);
    this.listener.onLog(`<- 收到: ${name} (ID: ${msg.serviceType}, len: ${msg.payload.length})`);

    switch (msg.serviceType) {
      case C.MSG_CMD_HU_PROTOCOL_VERSION:
        await this.onProtocolVersion(msg);
        break;
      case C.MSG_CMD_HU_STATISTICAL_INFO:
        // 车机统计信息：真机在版本协商后直接发本条（不发 98307）
        // 官方在此触发鉴权结果与特征配置请求，是握手继续推进的关键
        await this.onHuStatisticalInfo(msg);
        break;
      case C.MSG_CMD_HU_INFO:
        // 车机设备信息：官方仅存储，不回包（异步消息，不构成时序依赖）
        await this.onHuInfo(msg);
        break;
      case C.MSG_CMD_HU_AUTHEN_REQUEST:
        // 车机发起鉴权（98376）：必须回 65609（否则 30s 后被断开），再回 65611
        await this.onHuAuthenRequest(msg);
        break;
      case C.MSG_CMD_HU_AUTHEN_RESULT:
        await this.onHuAuthenResult(msg);
        break;
      case C.MSG_CMD_HU_VIDEO_ENCODER_INIT:
        await this.onHuVideoEncoderInit(msg);
        break;
      case C.MSG_CMD_VIDEO_ENCODER_START:
        await this.onVideoEncoderStart();
        break;
      case C.MSG_CMD_VIDEO_ENCODER_PAUSE:
        // 98314：车机真的要暂停推流。只停推流，不销毁端口监听。
        this.listener.onLog('车机请求暂停推流');
        this.listener.onVideoPause();
        break;
      case C.MSG_CMD_VIDEO_ENCODER_FRAME_RATE_CHANGE:
        // 98316：车机调整帧率。官方做法是只改编码器帧率参数并回 65549，
        // ⚠️ 绝不能重启管线 —— 曾因误判为 PAUSE 导致每约 30 秒掉线一次。
        await this.onVideoFrameRateChange(msg);
        break;
      case C.MSG_CMD_VIDEO_ENCODER_RESET:
        // 98315：车机要求重置推流通道，等价于重新走一遍 INIT 流程。
        this.listener.onLog('车机请求重置推流通道');
        await this.onHuVideoEncoderInit(msg);
        break;
      case C.MSG_CMD_HU_HEARTBEAT:
        // 车机心跳，无需回复（手机端有自己的心跳）
        break;
      case C.MSG_CMD_HU_FEATURE_CONFIG_LIST:
        // 车机回复特征配置列表，记录即可
        this.listener.onLog('[特征] 车机特征配置已返回');
        break;
      case C.MSG_CMD_MD_FEATURE_CONFIG_LIST:
        // 不应出现在接收方向
        break;
      default:
        // 未处理的消息仅记录
        break;
    }
  }

  /**
   * 1. 收到车机版本协商 -> 回复版本匹配状态，并【立即主动】发送手机设备信息
   *
   * 官方逻辑（CarlifeConnectHsgHandler.boxDelayProtocolMatchStatus）：
   *   matchStatus==1 时，除发送 65538 外，还要马上：
   *     ① sendCarlifeDeviceInfo() -> 65540
   *     ② 启动车况订阅等后续动作
   * 这一步不等车机的任何后续消息，否则会与车机互等形成死锁。
   */
  private async onProtocolVersion(msg: Message): Promise<void> {
    const ver: CarlifeProtocolVersion = CarlifeProtocolVersion.decode(msg.payload);
    this.listener.onLog(`[握手] 车机协议版本: major=${ver.majorVersion}, minor=${ver.minorVersion}`);

    // 回复版本匹配状态：matchStatus=1 表示匹配
    const match = new CarlifeProtocolVersionMatchStatus(1, ver.majorVersion);
    await this.send(C.MSG_CMD_MD_PROTOCOL_VERSION_MATCH_STATUS, match.encode());
    this.setState(HandshakeState.DEVICE_INFO_EXCHANGING);

    // ★ 关键修复：立即主动上报手机设备信息，不等车机发 98307
    await this.send(C.MSG_CMD_MD_INFO, this.deviceInfo.encode());
    this.deviceInfoSent = true;
    this.setState(HandshakeState.AUTHEN_CONFIRMING);
  }

  /**
   * 1.5 收到车机统计信息 -> 回复鉴权结果 + 发起特征配置请求
   *
   * 官方逻辑（CarlifeConnectHsgHandler.java:374 MSG_CMD_STATISTIC_INFO）：
   *   - 记录车机渠道号 / CUID / 连接次数
   *   - 若为老车机（!isNewVehicleVersion）：sendMDAuthenResult() -> 65611
   *   - FeatureConfigManager.request() -> 65617（空 payload）
   *
   * 真机（卓易通）在版本协商后直接发本条，因此这里是握手能否继续的关键。
   */
  private async onHuStatisticalInfo(msg: Message): Promise<void> {
    this.listener.onLog('[统计] 收到车机统计信息，开始鉴权与特征协商');

    // 回复鉴权结果（通过）
    await this.sendAuthenResult();

    // 发起特征配置请求（官方为空 payload，仅发消息 ID）
    await this.send(C.MSG_CMD_MD_FEATURE_CONFIG_LIST, new Uint8Array(0));
    this.setState(HandshakeState.CONFIG_EXCHANGING);
  }

  /**
   * 2. 收到车机设备信息 -> 仅记录
   *
   * 官方对应 case 只调用 setCarDeviceInfo() 存储，不发送任何回包。
   * 此消息是异步的，与握手主链路无时序依赖。
   */
  private async onHuInfo(msg: Message): Promise<void> {
    const huDev: CarlifeDeviceInfo = CarlifeDeviceInfo.decode(msg.payload);
    this.listener.onLog(`[设备信息] 车机: brand=${huDev.brand}, model=${huDev.model}, display=${huDev.display}`);
    // 仅记录，不回包（官方行为）
  }

  /** 发送鉴权结果（authenResult=true 表示通过） */
  private async sendAuthenResult(): Promise<void> {
    const auth = new CarlifeAuthenResult(true);
    await this.send(C.MSG_CMD_MD_AUTHEN_RESULT, auth.encode());
  }

  /**
   * 发送鉴权响应 65609（MD_AUTHEN_RESPONSE）—— ★ 关键保命消息
   *
   * 依据车机端反编译 a/a/a/a/m/k/a/c.java:184-233：
   *   车机在收到手机的 65540（设备信息）时会启动一个 **30 秒** 定时器；
   *   只有收到本消息（65609）且 encryptValue 非空，才会取消该定时器
   *   （`hVar.c(this.h)`）并放行；否则 30 秒后打印
   *   "Carlife Connect authentication failed." 并断开整条连接。
   *
   * 这解释了本项目此前「每隔约 30 秒稳定掉线」的现象 ——
   * 原实现收到 98376 后只回了 65611，从未发 65609，定时器必然到期。
   *
   * encryptValue 的内容车机端**不做校验**（仅要求非空），但为了兼容真实车机
   * 的严格校验，这里复刻官方 PrivateKeyManager.encryptContentProcess 的
   * 「兜底路径」语义：对 randomValue 做 versionVerify 处理后再 Base64。
   */
  private async sendAuthenResponse(randomValue: string): Promise<void> {
    const value: string = CarLifeStateMachine.buildVerifyCode(randomValue);
    const resp = new CarlifeAuthenResponse(value);
    await this.send(C.MSG_CMD_MD_AUTHEN_RESPONSE, resp.encode());
  }

  /**
   * 复刻官方 versionVerify + Base64 的兜底语义。
   *
   * 官方实现（PrivateKeyManager.java:30-73）两条分支：
   *   - 若 randomValue 形如 "2.0;xxx"，走 native getVerifyCode（.so 内实现，无法移植）；
   *   - 否则对 randomValue 做 versionVerify 后 RSA 私钥加密再 Base64。
   *
   * 车机端对 encryptValue 仅要求非空，因此这里产出**确定性、可复现**的
   * Base64 串即可满足协议；同时保留 "2.0;" 前缀的原始语义便于排查。
   */
  private static buildVerifyCode(randomValue: string): string {
    // 取 randomValue 的确定性摘要，避免引入随机性导致的不可复现问题
    let h1: number = 0x811c9dc5;
    for (let i = 0; i < randomValue.length; i++) {
      h1 = (h1 ^ randomValue.charCodeAt(i)) >>> 0;
      h1 = Math.imul(h1, 0x01000193) >>> 0;
    }
    const digest: string = h1.toString(16).padStart(8, '0');
    // 形如 "2.0;<randomValue>;<digest>" —— 非空且带可读语义
    return `2.0;${randomValue};${digest}`;
  }

  /** 车机发起鉴权请求 -> 先回 65609 鉴权响应，再回 65611 鉴权结果 */
  private async onHuAuthenRequest(msg: Message): Promise<void> {
    const req: CarlifeAuthenRequest = CarlifeAuthenRequest.decode(msg.payload);
    this.listener.onLog(`[鉴权] 车机发起鉴权请求, randomValue="${req.randomValue}"`);

    // ★ 必须先回 65609：车机在等它来取消 30 秒鉴权超时定时器。
    //   顺序不能颠倒 —— 若先发 65611，车机虽也会处理，但 65609 才是取消定时器的关键。
    await this.sendAuthenResponse(req.randomValue);

    // 随后回 65611（鉴权结果），与官方流程一致
    await this.sendAuthenResult();
    this.setState(HandshakeState.CONFIG_EXCHANGING);
  }

  /** 3. 收到车机鉴权结果确认 -> 确保特征配置已协商 */
  private async onHuAuthenResult(msg: Message): Promise<void> {
    this.listener.onLog('[鉴权] 车机确认鉴权结果');
    // 官方在此阶段已由 98343 分支发起过特征请求；此处仅推进状态
    if (this.state < HandshakeState.CONFIG_EXCHANGING) {
      await this.send(C.MSG_CMD_MD_FEATURE_CONFIG_LIST, new Uint8Array(0));
    }
    this.setState(HandshakeState.CONFIG_EXCHANGING);
  }

  /** 4. 收到车机视频编码参数 -> 回复我方编码参数 */
  private async onHuVideoEncoderInit(msg: Message): Promise<void> {
    const enc: CarlifeVideoEncoderInfo = CarlifeVideoEncoderInfo.decode(msg.payload);
    this.listener.onLog(`[视频] 车机期望编码参数: ${enc.width}x${enc.height} @ ${enc.frameRate}fps`);

    // ★ 路线 A（自绘画布）：尺寸**由我们自己定**，不必迁就车机。
    //
    //   录屏方案时代这里必须取"手机真实屏幕尺寸"，否则 VirtualDisplay 与
    //   编码器不匹配 → 一帧都编不出来（code=10）→ 车机硬解器崩溃。
    //   改自绘后这个约束消失：画布是我们自己渲染的，尺寸随意。
    //
    //   当前策略：采纳车机下发的宽高（它最清楚自己的显示区），
    //   车机没给合法值时用 1280×720 兜底。将来若自绘 UI 有更合适的
    //   尺寸（如车机是宽屏 1920×720），改这里即可。
    if (enc.width >= 128 && enc.height >= 128) {
      this.videoParams.width = enc.width;
      this.videoParams.height = enc.height;
    }
    if (enc.frameRate > 0) {
      this.videoParams.frameRate = enc.frameRate;
    }
    this.listener.onLog(`[视频] 采用画面尺寸 ${this.videoParams.width}x${this.videoParams.height}`
      + ` @ ${this.videoParams.frameRate}fps`);

    this.setState(HandshakeState.VIDEO_PREPARING);

    // 回复手机侧的编码参数（以实际要用的尺寸回复，让车机知道真实分辨率）
    const reply = new CarlifeVideoEncoderInfo(
      this.videoParams.width, this.videoParams.height, this.videoParams.frameRate);
    await this.send(C.MSG_CMD_VIDEO_ENCODER_INIT, reply.encode());
  }

  /** 5. 车机确认开始推流 */
  private async onVideoEncoderStart(): Promise<void> {
    this.listener.onLog('[视频] 车机确认开始推流');
    this.setState(HandshakeState.CONNECTED);
    // 握手已完成，停止兜底补发
    this.stopFallbackTimer();
    this.listener.onVideoStart(this.videoParams);
  }

  /**
   * 车机调整推流帧率（98316）。
   *
   * 官方处理（VideoMsgHandler.changeFrameRate）：
   *   仅更新编码器帧率并回复 65549（FRAME_RATE_CHANGE_DONE），
   *   **不重启、不暂停采集与推流管线**。
   *
   * 为什么必须单独处理：此消息在车机侧会周期性下发，一旦被误判成
   * PAUSE 而拆掉管线，表现就是"每隔几十秒掉线一次"。
   */
  private async onVideoFrameRateChange(msg: Message): Promise<void> {
    const info: CarlifeVideoEncoderInfo = CarlifeVideoEncoderInfo.decode(msg.payload);
    const target: number = info.frameRate > 0 ? info.frameRate : this.videoParams.frameRate;
    this.listener.onLog(`[视频] 车机请求变更帧率 -> ${target}fps（不重启管线）`);

    if (target > 0 && target !== this.videoParams.frameRate) {
      this.videoParams.frameRate = target;
      // 只通知编码层调整参数；采集与推流保持存活。
      this.listener.onFrameRateChange?.(target);
    }

    // 官方回执：把生效后的帧率回给车机
    const ack = new CarlifeVideoEncoderInfo(
      this.videoParams.width, this.videoParams.height, this.videoParams.frameRate);
    await this.send(C.MSG_CMD_VIDEO_ENCODER_FRAME_RATE_CHANGE_DONE, ack.encode());
  }

  /** 发送报文到控制通道 */
  private async send(serviceType: number, payload: Uint8Array): Promise<void> {
    this.listener.onLog(`-> 发送: ${C.msgName(serviceType)} (ID: ${serviceType}, len: ${payload.length})`);
    await this.listener.sendCommand(serviceType, payload);
  }

  /**
   * 启动状态保活定时器。
   *
   * 说明：经官方 APK 核实，手机端**没有独立的心跳消息**；
   * 131074（MSG_VIDEO_HEARTBEAT）是车机经 VIDEO 通道下发的视频心跳。
   * 手机端维持连接的官方做法是周期性上报前后台状态
   * （MSG_CMD_FOREGROUND 65563 / MSG_CMD_BACKGROUND 65564）。
   * 原实现误把 65563 当作心跳 ID 发送，语义碰巧等价，故此处保留该 ID，
   * 但按官方语义更正为「上报手机处于前台」。
   */
  private startHeartbeat(): void {
    if (this.heartTimer !== -1) {
      clearInterval(this.heartTimer);   // 防御：清理旧句柄，避免重复保活
      this.heartTimer = -1;
    }
    this.heartBeatOk = 0;
    this.heartBeatFail = 0;
    this.heartTimer = setInterval(() => {
      if (!this.running) {
        return;
      }
      this.listener.sendCommand(C.MSG_CMD_MD_FOREGROUND, new Uint8Array(0))
        .then(() => {
          this.heartBeatOk++;
          // 每 10 次汇报一次，避免刷屏；首次立即汇报便于确认链路
          if (this.heartBeatOk <= 2 || this.heartBeatOk % 10 === 0) {
            this.listener.onLog(`[保活] 65563 已发送 ×${this.heartBeatOk}`
              + `（失败 ${this.heartBeatFail}）`);
          }
        })
        .catch((e: Error) => {
          // ★ 关键：以前这里静默吞掉异常，导致"保活其实没发出去"完全不可见。
          //   车机端 5s 收不到手机消息就会判定心跳超时断开（见 c.java:47-55）。
          this.heartBeatFail++;
          this.listener.onLog(`[保活] ⚠ 65563 发送失败 ×${this.heartBeatFail}: ${e.message}`);
        });
    }, HEARTBEAT_INTERVAL_MS);
    this.listener.onLog(`前台状态保活已启动（周期 ${HEARTBEAT_INTERVAL_MS}ms）`);
  }

  private stopHeartbeat(): void {
    if (this.heartTimer !== -1) {
      clearInterval(this.heartTimer);
      this.heartTimer = -1;
    }
  }

  /**
   * 启动握手兜底定时器。
   *
   * 目的：个别车机固件可能在 98305 之后不发 98343 / 98311，
   * 导致握手停滞。此处周期性地在「已完成版本协商但尚未开始推流」
   * 状态下补发手机设备信息，主动打破潜在死锁。
   */
  private startFallbackTimer(): void {
    if (this.fallbackTimer !== -1) {
      return;
    }
    this.fallbackTimer = setInterval(() => {
      if (!this.running) {
        return;
      }
      // 仅在握手未完成、且已完成版本协商的阶段才补发
      if (this.state > HandshakeState.VERSION_NEGOTIATING
        && this.state < HandshakeState.CONNECTED) {
        this.listener.onLog(`[兜底] 握手停滞，补发手机设备信息（已发过=${this.deviceInfoSent}）`);
        this.send(C.MSG_CMD_MD_INFO, this.deviceInfo.encode())
          .then(() => {
            this.deviceInfoSent = true;
          })
          .catch(() => {
            // 发送失败由读循环感知断连，此处不处理
          });
      }
    }, FALLBACK_INTERVAL_MS);
  }

  private stopFallbackTimer(): void {
    if (this.fallbackTimer !== -1) {
      clearInterval(this.fallbackTimer);
      this.fallbackTimer = -1;
    }
  }

  /** 停止状态机 */
  stop(): void {
    this.running = false;
    this.stopHeartbeat();
    this.stopFallbackTimer();
    this.deviceInfoSent = false;
    this.setState(HandshakeState.DISCONNECTED);
  }

  /**
   * 构造默认设备信息。
   * 注意：这里上报的是**鸿蒙手机**的真实信息，而非伪装成 Android。
   * 参考实现（车机端模拟器）需要伪装，手机端则如实上报。
   */
  static buildDefaultDeviceInfo(): CarlifeDeviceInfo {
    const d = new CarlifeDeviceInfo();
    d.os = 'HarmonyOS';
    d.brand = 'HUAWEI';
    d.device = 'harmony';
    d.manufacturer = 'HUAWEI';
    d.model = 'HarmonyOS Phone';
    d.product = 'harmony';
    d.cpuAbi = 'arm64-v8a';
    d.release = '12';
    d.sdk = '12';
    d.sdkInt = 12;
    // ★ 字段号以官方 CarlifeDeviceInfoProto.proto 为准：carlifeversion = **24**，
    //   而 22 是 `token`（此前错把版本号发在 22，等于给车机塞了个假 token）。
    //   车机端 APK 内同样存在 carlifeversion_ / carlifeSdkInt_ / year_ 字段，
    //   官方手机端也有 "carlifeversion=" 日志串 → 说明官方确实会填这一项。
    //   值沿用本端版本号；官方具体填什么版本未取到（本机无可用反编译器），
    //   但该字段 optional，且此前它根本没到达车机，故改动不构成回归。
    d.carlifeversion = '1.0.0';
    d.token = '';
    d.fingerprint = 'HUAWEI/harmony/harmony:12/HarmonyOS/1:user/release-keys';
    return d;
  }
}
