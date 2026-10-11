/**
 * CarLife 协议常量定义
 *
 * 对齐参考实现：refs/carlife_pc_tool/protocol/constants.py
 * 上游依据：百度 CarLife 车机端混淆源码
 *   - 通道与端口：sources/d/b/a/a/p/o/e/c.java:16
 *   - UDP 发现端口：sources/d/b/a/a/p/o/e/d.java:146
 *   - 消息 ID 映射表：sources/d/b/a/a/o/h/e/b.java:963-1022
 */

// ================= 通道 (Channel) 与端口 (Port) =================
export const CHANNEL_CMD: number = 1;      // 控制/信令通道
export const PORT_CMD: number = 7240;

export const CHANNEL_VIDEO: number = 2;    // 视频流通道
export const PORT_VIDEO: number = 8240;

export const CHANNEL_AUDIO: number = 3;    // 媒体音频/音乐通道
export const PORT_AUDIO: number = 9240;

export const CHANNEL_TTS: number = 4;      // 导航语音/TTS通道
export const PORT_TTS: number = 9241;

export const CHANNEL_VR: number = 5;       // 语音识别通道
export const PORT_VR: number = 9242;

export const CHANNEL_TOUCH: number = 6;    // 触控/按键交互通道
export const PORT_TOUCH: number = 9340;

export const CHANNEL_DATA: number = 7;     // 车辆传感器与数据通道
export const PORT_DATA: number = 9440;

/** 全部通道定义：[通道号, 端口号, 描述] */
export interface ChannelDef {
  channel: number;
  port: number;
  desc: string;
}

export const ALL_CHANNELS: ChannelDef[] = [
  { channel: CHANNEL_CMD, port: PORT_CMD, desc: 'Command/Control' },
  { channel: CHANNEL_VIDEO, port: PORT_VIDEO, desc: 'Video' },
  { channel: CHANNEL_AUDIO, port: PORT_AUDIO, desc: 'MediaAudio' },
  { channel: CHANNEL_TTS, port: PORT_TTS, desc: 'TTSAudio' },
  { channel: CHANNEL_VR, port: PORT_VR, desc: 'VRAudio' },
  { channel: CHANNEL_TOUCH, port: PORT_TOUCH, desc: 'Touch/Input' },
  { channel: CHANNEL_DATA, port: PORT_DATA, desc: 'CarData' }
];

/** Wi-Fi 发现广播端口（车端在此端口监听手机端广播） */
export const UDP_DISCOVERY_PORT: number = 7999;

// ================= 握手与版本协商 (Channel 1) =================
/** 0x00018001: 车端发起版本协商 (CarlifeProtocolVersion) */
export const MSG_CMD_HU_PROTOCOL_VERSION: number = 98305;
/** 0x00010002: 手机回复版本匹配状态 (CarlifeProtocolVersionMatchStatus) */
export const MSG_CMD_MD_PROTOCOL_VERSION_MATCH_STATUS: number = 65538;
/** 0x00018027: 车端发送统计信息 (CarlifeStatisticsInfo) */
export const MSG_CMD_HU_STATISTICAL_INFO: number = 98343;

// ================= 设备信息与鉴权 (Channel 1) =================
/** 0x00018003: 车端回复设备信息 (CarlifeDeviceInfo) */
export const MSG_CMD_HU_INFO: number = 98307;
/** 0x00010004: 手机发送设备信息 (CarlifeDeviceInfo) */
export const MSG_CMD_MD_INFO: number = 65540;
/** 0x0001004B: 手机发送鉴权结果 (CarlifeAuthenResult) */
export const MSG_CMD_MD_AUTHEN_RESULT: number = 65611;
/** 0x0001804C: 车端确认鉴权结果 */
export const MSG_CMD_HU_AUTHEN_RESULT: number = 98380;

// ================= 特征配置 (Channel 1) =================
/** 0x00010051: 手机请求配置列表 (CarlifeFeatureConfigList) */
export const MSG_CMD_MD_FEATURE_CONFIG_LIST: number = 65617;
/** 0x00018052: 车端回复配置列表 (CarlifeFeatureConfigList) */
export const MSG_CMD_HU_FEATURE_CONFIG_LIST: number = 98386;

// ================= 前后台状态与心跳 (Channel 1) =================
/** 0x00010018: 手机端 CarLife 进入前台 */
export const MSG_CMD_MD_FOREGROUND: number = 65560;
/** 0x00010019: 手机端 CarLife 退入后台 */
export const MSG_CMD_MD_BACKGROUND: number = 65561;
/** 0x0001001B: 手机端向车机发送的保活心跳 */
export const MSG_CMD_MD_HEARTBEAT: number = 65563;
/** 0x00010021: 返回车机主页 */
export const MSG_CMD_MD_BACK_TO_HOME: number = 65569;

// ================= 其它控制消息 (Channel 1) =================
/** 0x00010022: 手机请求开启语音唤醒监听录音 (VR) */
export const MSG_CMD_MD_MIC_RECORD_WAKEUP_START: number = 65570;
/** 0x00010023: 语音录音结束 */
export const MSG_CMD_MD_MIC_RECORD_END: number = 65571;
/** 0x00010024: 语音识别录音开始 */
export const MSG_CMD_MD_MIC_RECORD_RECOG_START: number = 65572;
/** 0x00010026: 手机端各模块状态变更列表 (CarlifeModuleStatusList) */
export const MSG_CMD_MD_MODULE_STATUS_LIST: number = 65574;
/** 0x00010030: 导航诱导转向信息 (CarlifeNaviNextTurnInfo) */
export const MSG_CMD_MD_NAVI_NEXT_TURN_INFO: number = 65584;
/** 0x00010031: 手机请求车端传感器支持列表 */
export const MSG_CMD_MD_REQ_VEHICLE_INFO: number = 65585;
/** 0x00010033: 手机订阅车况 */
export const MSG_CMD_MD_SUBSCRIBE_VEHICLE_INFO: number = 65587;
/** 0x00010034: 手机取消订阅车况 */
export const MSG_CMD_MD_UNSUBSCRIBE_VEHICLE_INFO: number = 65588;
/** 0x00010035: 手机拉取车况数据 */
export const MSG_CMD_MD_REQ_VEHICLE_DATA: number = 65589;
/** 0x00010036: 手机端周期性推送的 GPS 与车载数据流 */
export const MSG_CMD_MD_CAR_DATA: number = 65590;
/** 0x00010043: 手机请求订阅移动 CarLife 信息 */
export const MSG_CMD_MD_REQ_SUBSCRIBE_MOBILE_INFO: number = 65603;
/** 0x00010044: 手机订阅移动端信息列表 */
export const MSG_CMD_MD_SUBSCRIBE_MOBILE_INFO_LIST: number = 65604;
/** 0x00010049: 鉴权响应 (CarlifeAuthenResponse) */
export const MSG_CMD_MD_AUTHEN_RESPONSE: number = 65609;
/** 0x00010060: 连接时间同步 (CarlifeConnectTimeSync) */
export const MSG_CMD_MD_CONNECT_TIME_SYNC: number = 65632;
/** 0x0001006A: 手机请求车机 RSA 公钥 */
export const MSG_CMD_MD_REQ_HU_RSA_PUBLIC_KEY: number = 65642;
/** 0x0001006C: 手机发送 AES 秘钥请求 (CarlifeMdAesKeyRequest) */
export const MSG_CMD_MD_AES_KEY_REQUEST: number = 65644;
/** 0x0001006E: AES 秘钥协商完成 */
export const MSG_CMD_MD_AES_KEY_DONE: number = 65646;
/** 0x0001006F: 车辆控制指令 (CarlifeVehicleControl) */
export const MSG_CMD_MD_VEHICLE_CONTROL: number = 65647;

// ================= 视频启动协商 (Channel 1) =================
/** 0x00010008: 手机提供编码参数 (CarlifeVideoEncoderInfo) */
export const MSG_CMD_VIDEO_ENCODER_INIT: number = 65544;
/** 0x0001000D: 手机视频帧率信息 (CarlifeVideoFrameRate) */
export const MSG_CMD_MD_VIDEO_FRAME_RATE: number = 65549;
/** 0x0001000F: 手机视频编码器准备好 */
export const MSG_CMD_VIDEO_ENCODER_INIT_DONE: number = 65551;
/** 0x00018007: 车端向手机通知期望的分辨率与帧率 (CarlifeVideoEncoderInfo) */
export const MSG_CMD_HU_VIDEO_ENCODER_INIT: number = 98311;
/** 0x00018009: 车端确认开始推流 (无负载) */
export const MSG_CMD_VIDEO_ENCODER_START: number = 98313;
/** 0x0001800C: 暂停推流 */
export const MSG_CMD_VIDEO_ENCODER_PAUSE: number = 98316;
/** 0x00018007: 重置推流 (同 HU_VIDEO_ENCODER_INIT) */
export const MSG_CMD_VIDEO_ENCODER_RESET: number = 98311;

// ================= 心跳与流媒体数据 =================
/** 0x00020002: 车端心跳包 */
export const MSG_CMD_HU_HEARTBEAT: number = 131074;
/** 0x00020001: 视频帧数据 (H.264 NALU) */
export const MSG_VIDEO_DATA: number = 131073;
/** 0x00030001: 媒体音频初始化 (CarlifeMusicInit) */
export const MSG_MEDIA_INIT: number = 196609;
/** 0x00030002: 媒体音频裸流 (PCM) */
export const MSG_MEDIA_DATA: number = 196610;
/** 0x00030006: 媒体音频停止 */
export const MSG_MEDIA_STOP: number = 196614;
/** 0x00040001: 导航TTS初始化 (CarlifeTTSInit) */
export const MSG_NAVI_TTS_INIT: number = 262145;
/** 0x00040002: 导航TTS停止 */
export const MSG_NAVI_TTS_STOP: number = 262146;
/** 0x00040003: 导航TTS裸流 (PCM) */
export const MSG_NAVI_TTS_DATA: number = 262147;
/** 0x00050002: 语音识别音频初始化 (CarlifeTTSInit) */
export const MSG_VR_AUDIO_INIT: number = 327682;
/** 0x00050003: 语音识别音频裸流 (PCM) */
export const MSG_VR_AUDIO_DATA: number = 327683;
/** 0x00050004: 语音识别音频停止 */
export const MSG_VR_AUDIO_STOP: number = 327684;

// ================= 触控与按键 (Channel 6) =================
/** 0x00068001: 触控事件 (CarlifeTouchAction) */
export const MSG_TOUCH_ACTION: number = 425985;
/** 0x00068002 */
export const MSG_TOUCH_ACTION_DOWN: number = 425986;
/** 0x00068003 */
export const MSG_TOUCH_ACTION_UP: number = 425987;
/** 0x00068004 */
export const MSG_TOUCH_ACTION_MOVE: number = 425988;
/** 0x00068005 */
export const MSG_TOUCH_ACTION_CLICK: number = 425989;
/** 0x0006800E: 多点触控 */
export const MSG_TOUCH_MULTI_POINT: number = 425998;
/** 0x00068008: 实体按键 (CarlifeCarHardKeyCode) */
export const MSG_HARD_KEY_CODE: number = 425992;

// ================= 车况数据 (Channel 7) =================
/** 0x0001800F: 车速 (CarlifeCarSpeed) */
export const MSG_CAR_SPEED: number = 98319;
/** 0x00018010: GPS信息 (CarlifeCarGps) */
export const MSG_CAR_GPS: number = 98320;
/** 0x00018011: 陀螺仪 (CarlifeGyroscope) */
export const MSG_CAR_GYRO: number = 98321;
/** 0x00018012: 加速度 (CarlifeAcceleration) */
export const MSG_CAR_ACCEL: number = 98322;
/** 0x00018013: 油耗 (CarlifeOil) */
export const MSG_CAR_OIL: number = 98323;
/** 0x00018029: 挡位 (CarlifeGearInfo) */
export const MSG_CAR_GEAR: number = 98345;

// ================= 触控动作类型 =================
export const ACTION_DOWN: number = 0;
export const ACTION_UP: number = 1;
export const ACTION_MOVE: number = 2;

// ================= 常用硬按键码 =================
export const KEYCODE_HOME: number = 1;
export const KEYCODE_BACK: number = 2;
export const KEYCODE_PHONE_CALL: number = 3;
export const KEYCODE_PHONE_END: number = 4;
export const KEYCODE_MEDIA: number = 5;

/**
 * 消息名称反向映射表（用于日志解析）
 * 依据 constants.py MSG_NAMES
 */
export function msgName(serviceType: number): string {
  const name: string | undefined = MSG_NAMES[serviceType];
  if (name !== undefined) {
    return name;
  }
  return `UNKNOWN_0x${serviceType.toString(16).padStart(8, '0').toUpperCase()}`;
}

const MSG_NAMES: Record<number, string> = {
  98305: 'HU_PROTOCOL_VERSION',
  65538: 'MD_PROTOCOL_VERSION_MATCH_STATUS',
  98343: 'HU_STATISTICAL_INFO',
  98307: 'HU_INFO',
  65540: 'MD_INFO',
  65611: 'MD_AUTHEN_RESULT',
  65609: 'MD_AUTHEN_RESPONSE',
  98380: 'HU_AUTHEN_RESULT',
  65617: 'MD_FEATURE_CONFIG_LIST',
  98386: 'HU_FEATURE_CONFIG_LIST',
  65560: 'MD_FOREGROUND',
  65561: 'MD_BACKGROUND',
  65563: 'MD_HEARTBEAT',
  65569: 'MD_BACK_TO_HOME',
  65570: 'MD_MIC_RECORD_WAKEUP_START',
  65571: 'MD_MIC_RECORD_END',
  65572: 'MD_MIC_RECORD_RECOG_START',
  65574: 'MD_MODULE_STATUS_LIST',
  65584: 'MD_NAVI_NEXT_TURN_INFO',
  65585: 'MD_REQ_VEHICLE_INFO',
  65587: 'MD_SUBSCRIBE_VEHICLE_INFO',
  65588: 'MD_UNSUBSCRIBE_VEHICLE_INFO',
  65589: 'MD_REQ_VEHICLE_DATA',
  65590: 'MD_CAR_DATA',
  65603: 'MD_REQ_SUBSCRIBE_MOBILE_INFO',
  65604: 'MD_SUBSCRIBE_MOBILE_INFO_LIST',
  65632: 'MD_CONNECT_TIME_SYNC',
  65642: 'MD_REQ_HU_RSA_PUBLIC_KEY',
  65644: 'MD_AES_KEY_REQUEST',
  65646: 'MD_AES_KEY_DONE',
  65647: 'MD_VEHICLE_CONTROL',
  65544: 'VIDEO_ENCODER_INIT',
  65549: 'MD_VIDEO_FRAME_RATE',
  65551: 'VIDEO_ENCODER_INIT_DONE',
  98311: 'HU_VIDEO_ENCODER_INIT',
  98313: 'VIDEO_ENCODER_START',
  98316: 'VIDEO_ENCODER_PAUSE',
  131073: 'VIDEO_DATA',
  131074: 'HU_HEARTBEAT',
  196609: 'MEDIA_INIT',
  196610: 'MEDIA_DATA',
  196614: 'MEDIA_STOP',
  262145: 'NAVI_TTS_INIT',
  262146: 'NAVI_TTS_STOP',
  262147: 'NAVI_TTS_DATA',
  327682: 'VR_AUDIO_INIT',
  327683: 'VR_AUDIO_DATA',
  327684: 'VR_AUDIO_STOP',
  425985: 'TOUCH_ACTION',
  425986: 'TOUCH_ACTION_DOWN',
  425987: 'TOUCH_ACTION_UP',
  425988: 'TOUCH_ACTION_MOVE',
  425989: 'TOUCH_ACTION_CLICK',
  425998: 'TOUCH_MULTI_POINT',
  425992: 'HARD_KEY_CODE',
  98319: 'CAR_SPEED',
  98320: 'CAR_GPS',
  98321: 'CAR_GYRO',
  98322: 'CAR_ACCEL',
  98323: 'CAR_OIL',
  98345: 'CAR_GEAR'
};
