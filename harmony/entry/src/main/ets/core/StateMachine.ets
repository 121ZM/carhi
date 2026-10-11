/**
 * CarLife 握手与控制状态机（Channel 1）
 *
 * 对齐参考实现：refs/carlife_pc_tool/core/state_machine.py（反向：车机侧 -> 手机侧）
 *
 * 上游依据：
 *   - 握手时序与心跳：sources/d/b/a/a/p/m/a/c.java:58-133
 *   - 特征协商与配置：sources/d/b/a/a/p/m/a/f.java:39-81
 *   - 视频启动应答：sources/d/b/a/a/p/k/b.java:43-98
 *
 * 重要：参考实现是「车机端」，本实现是「手机端」，因此消息方向正好相反。
 * 下表为本实现（手机端）的收发方向：
 *
 *   收 HU_PROTOCOL_VERSION(98305)   -> 发 MD_PROTOCOL_VERSION_MATCH_STATUS(65538)
 *   收 HU_INFO(98307)               -> 发 MD_INFO(65540)
 *   收 HU_AUTHEN_RESULT(98380)      -> 发 MD_AUTHEN_RESULT(65611)
 *   收 HU_VIDEO_ENCODER_INIT(98311) -> 记录参数，发 VIDEO_ENCODER_INIT(65544)
 *   收 VIDEO_ENCODER_START(98313)   -> 开始推流
 *   周期性发 MD_HEARTBEAT(65563)
 */

import { Message } from '../protocol/Framing';
import * as C from '../protocol/Constants';
import {
  CarlifeProtocolVersion,
  CarlifeProtocolVersionMatchStatus,
  CarlifeDeviceInfo,
  CarlifeAuthenResult,
  CarlifeFeatureConfig,
  CarlifeFeatureConfigList,
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
  /** 需要发送报文到控制通道 */
  sendCommand: (serviceType: number, payload: Uint8Array) => Promise<void>;
}

/** 心跳周期（毫秒）。参考实现为 1000ms，依据 c.java:44-55 */
const HEARTBEAT_INTERVAL_MS: number = 1000;

export class CarLifeStateMachine {
  private listener: StateMachineListener;
  private state: HandshakeState = HandshakeState.DISCONNECTED;
  private heartTimer: number = -1;
  private running: boolean = false;

  /** 车机下发的视频参数，默认 720p@30（参考实现默认值） */
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
   * 注意：参考实现中「车机」是握手发起方（主动发 98305），
   * 手机端作为被动方等待车机发起。因此这里不需要主动发包，
   * 只需启动心跳并等待车机消息。
   */
  start(): void {
    this.running = true;
    this.setState(HandshakeState.VERSION_NEGOTIATING);
    this.startHeartbeat();
  }

  /** 处理控制通道收到的报文 */
  async handleMessage(msg: Message): Promise<void> {
    const name: string = C.msgName(msg.serviceType);
    this.listener.onLog(`<- 收到: ${name} (ID: ${msg.serviceType}, len: ${msg.payload.length})`);

    switch (msg.serviceType) {
      case C.MSG_CMD_HU_PROTOCOL_VERSION:
        await this.onProtocolVersion(msg);
        break;
      case C.MSG_CMD_HU_INFO:
        await this.onHuInfo(msg);
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
        this.listener.onLog('车机请求暂停推流');
        this.listener.onVideoPause();
        break;
      case C.MSG_CMD_HU_HEARTBEAT:
        // 车机心跳，无需回复（手机端有自己的心跳）
        break;
      case C.MSG_CMD_HU_FEATURE_CONFIG_LIST:
        // 车机回复特征配置列表，记录即可
        break;
      case C.MSG_CMD_MD_FEATURE_CONFIG_LIST:
        // 不应出现在接收方向
        break;
      default:
        // 未处理的消息仅记录
        break;
    }
  }

  /** 1. 收到车机版本协商 -> 回复版本匹配状态 */
  private async onProtocolVersion(msg: Message): Promise<void> {
    const ver: CarlifeProtocolVersion = CarlifeProtocolVersion.decode(msg.payload);
    this.listener.onLog(`[握手] 车机协议版本: major=${ver.majorVersion}, minor=${ver.minorVersion}`);

    // 回复版本匹配状态：matchStatus=1 表示匹配
    const match = new CarlifeProtocolVersionMatchStatus(1, ver.majorVersion);
    await this.send(C.MSG_CMD_MD_PROTOCOL_VERSION_MATCH_STATUS, match.encode());
    this.setState(HandshakeState.DEVICE_INFO_EXCHANGING);
  }

  /** 2. 收到车机设备信息 -> 回复手机设备信息 */
  private async onHuInfo(msg: Message): Promise<void> {
    const huDev: CarlifeDeviceInfo = CarlifeDeviceInfo.decode(msg.payload);
    this.listener.onLog(`[设备信息] 车机: brand=${huDev.brand}, model=${huDev.model}, display=${huDev.display}`);

    await this.send(C.MSG_CMD_MD_INFO, this.deviceInfo.encode());
    this.setState(HandshakeState.AUTHEN_CONFIRMING);
  }

  /** 3. 收到车机鉴权确认 -> 发送鉴权结果 */
  private async onHuAuthenResult(msg: Message): Promise<void> {
    this.listener.onLog('[鉴权] 车机确认鉴权结果');

    // 发送鉴权结果（true 表示通过）
    const auth = new CarlifeAuthenResult(true);
    await this.send(C.MSG_CMD_MD_AUTHEN_RESULT, auth.encode());
    this.setState(HandshakeState.CONFIG_EXCHANGING);

    // 同时发送特征配置列表
    await this.sendFeatureConfig();
  }

  /** 发送特征配置列表 */
  private async sendFeatureConfig(): Promise<void> {
    const list = new CarlifeFeatureConfigList();
    const features: CarlifeFeatureConfig[] = [
      new CarlifeFeatureConfig('USB_MTU', 16384),
      new CarlifeFeatureConfig('I_FRAME_INTERVAL', 300),
      new CarlifeFeatureConfig('CONNECT_TYPE', 2)   // 2 = 无线
    ];
    list.cnt = features.length;
    list.featureConfig = features;
    list.huBtName = 'CarLife_Phone';
    await this.send(C.MSG_CMD_MD_FEATURE_CONFIG_LIST, list.encode());
  }

  /** 4. 收到车机视频编码参数 -> 回复编码参数确认 */
  private async onHuVideoEncoderInit(msg: Message): Promise<void> {
    const enc: CarlifeVideoEncoderInfo = CarlifeVideoEncoderInfo.decode(msg.payload);
    if (enc.width > 0) { this.videoParams.width = enc.width; }
    if (enc.height > 0) { this.videoParams.height = enc.height; }
    if (enc.frameRate > 0) { this.videoParams.frameRate = enc.frameRate; }
    this.listener.onLog(`[视频] 车机期望编码参数: ${this.videoParams.width}x${this.videoParams.height} @ ${this.videoParams.frameRate}fps`);

    this.setState(HandshakeState.VIDEO_PREPARING);

    // 回复手机侧的编码参数（与车机期望一致）
    const reply = new CarlifeVideoEncoderInfo(
      this.videoParams.width, this.videoParams.height, this.videoParams.frameRate);
    await this.send(C.MSG_CMD_VIDEO_ENCODER_INIT, reply.encode());
  }

  /** 5. 车机确认开始推流 */
  private async onVideoEncoderStart(): Promise<void> {
    this.listener.onLog('[视频] 车机确认开始推流');
    this.setState(HandshakeState.CONNECTED);
    this.listener.onVideoStart(this.videoParams);
  }

  /** 发送报文到控制通道 */
  private async send(serviceType: number, payload: Uint8Array): Promise<void> {
    this.listener.onLog(`-> 发送: ${C.msgName(serviceType)} (ID: ${serviceType}, len: ${payload.length})`);
    await this.listener.sendCommand(serviceType, payload);
  }

  /** 启动心跳定时器 */
  private startHeartbeat(): void {
    if (this.heartTimer !== -1) {
      return;
    }
    this.heartTimer = setInterval(() => {
      if (!this.running) {
        return;
      }
      this.listener.sendCommand(C.MSG_CMD_MD_HEARTBEAT, new Uint8Array(0))
        .catch(() => {
          // 心跳失败不做特殊处理，连接断开由读循环感知
        });
    }, HEARTBEAT_INTERVAL_MS);
    this.listener.onLog(`心跳保活已启动（周期 ${HEARTBEAT_INTERVAL_MS}ms）`);
  }

  private stopHeartbeat(): void {
    if (this.heartTimer !== -1) {
      clearInterval(this.heartTimer);
      this.heartTimer = -1;
    }
  }

  /** 停止状态机 */
  stop(): void {
    this.running = false;
    this.stopHeartbeat();
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
    d.carlifeversion = '1.0.0';
    d.fingerprint = 'HUAWEI/harmony/harmony:12/HarmonyOS/1:user/release-keys';
    return d;
  }
}
