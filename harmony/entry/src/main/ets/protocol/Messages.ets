/**
 * CarLife 协议消息定义（Protobuf 结构）
 *
 * 对齐参考实现：refs/carlife_pc_tool/protocol/proto_codec.py
 * 上游依据：sources/com/baidu/carlife/protobuf/*.java
 *
 * 每个消息提供 encode() / decode() 两个静态方法，手写字段映射。
 * 字段编号严格对齐 proto 定义，不可随意调整。
 */

import { ProtobufWriter, ProtobufReader, utf8Decode, Field, WIRE_LENGTH_DELIMITED } from './Protobuf';

// ============================================================
// 1. CarlifeProtocolVersion
//    majorVersion=1(int32), minorVersion=2(int32)
// ============================================================
export class CarlifeProtocolVersion {
  majorVersion: number = 0;
  minorVersion: number = 0;

  constructor(majorVersion: number = 0, minorVersion: number = 0) {
    this.majorVersion = majorVersion;
    this.minorVersion = minorVersion;
  }

  encode(): Uint8Array {
    const w = new ProtobufWriter();
    if (this.majorVersion !== 0) {
      w.writeInt32(1, this.majorVersion);
    }
    if (this.minorVersion !== 0) {
      w.writeInt32(2, this.minorVersion);
    }
    return w.toBytes();
  }

  static decode(data: Uint8Array): CarlifeProtocolVersion {
    const msg = new CarlifeProtocolVersion();
    const r = new ProtobufReader(data);
    while (!r.eof) {
      const f: Field = r.readField();
      if (f.fieldNumber === 1) {
        msg.majorVersion = f.varintValue;
      } else if (f.fieldNumber === 2) {
        msg.minorVersion = f.varintValue;
      }
    }
    return msg;
  }
}

// ============================================================
// 2. CarlifeProtocolVersionMatchStatus
//    matchStatus=1(int32), carlifeProtocolVersion=2(int32)
// ============================================================
export class CarlifeProtocolVersionMatchStatus {
  matchStatus: number = 0;
  carlifeProtocolVersion: number = 0;

  constructor(matchStatus: number = 0, carlifeProtocolVersion: number = 0) {
    this.matchStatus = matchStatus;
    this.carlifeProtocolVersion = carlifeProtocolVersion;
  }

  encode(): Uint8Array {
    const w = new ProtobufWriter();
    if (this.matchStatus !== 0) {
      w.writeInt32(1, this.matchStatus);
    }
    if (this.carlifeProtocolVersion !== 0) {
      w.writeInt32(2, this.carlifeProtocolVersion);
    }
    return w.toBytes();
  }

  static decode(data: Uint8Array): CarlifeProtocolVersionMatchStatus {
    const msg = new CarlifeProtocolVersionMatchStatus();
    const r = new ProtobufReader(data);
    while (!r.eof) {
      const f: Field = r.readField();
      if (f.fieldNumber === 1) {
        msg.matchStatus = f.varintValue;
      } else if (f.fieldNumber === 2) {
        msg.carlifeProtocolVersion = f.varintValue;
      }
    }
    return msg;
  }
}

// ============================================================
// 3. CarlifeDeviceInfo
//    字段 1-27，**照 refs/carlife_proto/CarlifeDeviceInfoProto.proto 抄**
//
//    ★ 2026-10-13 修正：此前把 `carlifeversion` 写在**字段 22**，是错的。
//      官方 proto 原文：
//          optional string token          = 22;
//          optional string btaddress      = 23;
//          optional string carlifeversion = 24;   ← 真正的字段号
//          optional int32  carlifeType    = 25;
//          optional string year           = 26;
//          optional int32  carlifeSdkInt  = 27;
//      即字段 22 的语义是 `token`，不是版本号。原实现等于把 "1.0.0" 当 token
//      发给了车机，而车机真正想读的 carlifeversion 一直没收到。
//      车机端 APK 里同样存在 `token_` / `carlifeversion_` / `year_` 字段，
//      且官方手机端有 `carlifeversion=`、`carlifeSdkInt=` 的日志格式串，
//      说明这两个字段官方**确实会填**。
// ============================================================
export class CarlifeDeviceInfo {
  os: string = '';
  board: string = '';
  bootloader: string = '';
  brand: string = '';
  cpuAbi: string = '';
  cpuAbi2: string = '';
  device: string = '';
  display: string = '';
  fingerprint: string = '';
  hardware: string = '';
  host: string = '';
  cid: string = '';
  manufacturer: string = '';
  model: string = '';
  product: string = '';
  serial: string = '';
  codename: string = '';
  incremental: string = '';
  release: string = '';
  sdk: string = '';
  sdkInt: number = 0;
  token: string = '';
  btaddress: string = '';
  carlifeversion: string = '';
  carlifeType: number = 0;
  year: string = '';
  carlifeSdkInt: number = 0;

  encode(): Uint8Array {
    const w = new ProtobufWriter();
    if (this.os !== '') { w.writeString(1, this.os); }
    if (this.board !== '') { w.writeString(2, this.board); }
    if (this.bootloader !== '') { w.writeString(3, this.bootloader); }
    if (this.brand !== '') { w.writeString(4, this.brand); }
    if (this.cpuAbi !== '') { w.writeString(5, this.cpuAbi); }
    if (this.cpuAbi2 !== '') { w.writeString(6, this.cpuAbi2); }
    if (this.device !== '') { w.writeString(7, this.device); }
    if (this.display !== '') { w.writeString(8, this.display); }
    if (this.fingerprint !== '') { w.writeString(9, this.fingerprint); }
    if (this.hardware !== '') { w.writeString(10, this.hardware); }
    if (this.host !== '') { w.writeString(11, this.host); }
    if (this.cid !== '') { w.writeString(12, this.cid); }
    if (this.manufacturer !== '') { w.writeString(13, this.manufacturer); }
    if (this.model !== '') { w.writeString(14, this.model); }
    if (this.product !== '') { w.writeString(15, this.product); }
    if (this.serial !== '') { w.writeString(16, this.serial); }
    if (this.codename !== '') { w.writeString(17, this.codename); }
    if (this.incremental !== '') { w.writeString(18, this.incremental); }
    if (this.release !== '') { w.writeString(19, this.release); }
    if (this.sdk !== '') { w.writeString(20, this.sdk); }
    if (this.sdkInt !== 0) { w.writeInt32(21, this.sdkInt); }
    if (this.token !== '') { w.writeString(22, this.token); }
    if (this.btaddress !== '') { w.writeString(23, this.btaddress); }
    if (this.carlifeversion !== '') { w.writeString(24, this.carlifeversion); }
    if (this.carlifeType !== 0) { w.writeInt32(25, this.carlifeType); }
    if (this.year !== '') { w.writeString(26, this.year); }
    if (this.carlifeSdkInt !== 0) { w.writeInt32(27, this.carlifeSdkInt); }
    return w.toBytes();
  }

  static decode(data: Uint8Array): CarlifeDeviceInfo {
    const msg = new CarlifeDeviceInfo();
    const r = new ProtobufReader(data);
    while (!r.eof) {
      const f: Field = r.readField();
      const s: string = (f.bytesValue !== null) ? utf8Decode(f.bytesValue) : '';
      if (f.fieldNumber === 1) { msg.os = s; }
      else if (f.fieldNumber === 2) { msg.board = s; }
      else if (f.fieldNumber === 3) { msg.bootloader = s; }
      else if (f.fieldNumber === 4) { msg.brand = s; }
      else if (f.fieldNumber === 5) { msg.cpuAbi = s; }
      else if (f.fieldNumber === 6) { msg.cpuAbi2 = s; }
      else if (f.fieldNumber === 7) { msg.device = s; }
      else if (f.fieldNumber === 8) { msg.display = s; }
      else if (f.fieldNumber === 9) { msg.fingerprint = s; }
      else if (f.fieldNumber === 10) { msg.hardware = s; }
      else if (f.fieldNumber === 11) { msg.host = s; }
      else if (f.fieldNumber === 12) { msg.cid = s; }
      else if (f.fieldNumber === 13) { msg.manufacturer = s; }
      else if (f.fieldNumber === 14) { msg.model = s; }
      else if (f.fieldNumber === 15) { msg.product = s; }
      else if (f.fieldNumber === 16) { msg.serial = s; }
      else if (f.fieldNumber === 17) { msg.codename = s; }
      else if (f.fieldNumber === 18) { msg.incremental = s; }
      else if (f.fieldNumber === 19) { msg.release = s; }
      else if (f.fieldNumber === 20) { msg.sdk = s; }
      else if (f.fieldNumber === 21) { msg.sdkInt = f.varintValue; }
      else if (f.fieldNumber === 22) { msg.token = s; }
      else if (f.fieldNumber === 23) { msg.btaddress = s; }
      else if (f.fieldNumber === 24) { msg.carlifeversion = s; }
      else if (f.fieldNumber === 25) { msg.carlifeType = f.varintValue; }
      else if (f.fieldNumber === 26) { msg.year = s; }
      else if (f.fieldNumber === 27) { msg.carlifeSdkInt = f.varintValue; }
    }
    return msg;
  }
}

// ============================================================
// 4. CarlifeStatisticsInfo
//    cuid=1, versionName=2, versionCode=3, channel=4,
//    connectCount=5, connectSuccessCount=6, connectTime=7, crashCycle=8
// ============================================================
export class CarlifeStatisticsInfo {
  cuid: string = '';
  versionName: string = '';
  versionCode: number = 0;
  channel: string = '';
  connectCount: number = 0;
  connectSuccessCount: number = 0;
  connectTime: number = 0;
  crashCycle: string = '';

  encode(): Uint8Array {
    const w = new ProtobufWriter();
    if (this.cuid !== '') { w.writeString(1, this.cuid); }
    if (this.versionName !== '') { w.writeString(2, this.versionName); }
    if (this.versionCode !== 0) { w.writeInt32(3, this.versionCode); }
    if (this.channel !== '') { w.writeString(4, this.channel); }
    if (this.connectCount !== 0) { w.writeInt32(5, this.connectCount); }
    if (this.connectSuccessCount !== 0) { w.writeInt32(6, this.connectSuccessCount); }
    if (this.connectTime !== 0) { w.writeInt32(7, this.connectTime); }
    if (this.crashCycle !== '') { w.writeString(8, this.crashCycle); }
    return w.toBytes();
  }

  static decode(data: Uint8Array): CarlifeStatisticsInfo {
    const msg = new CarlifeStatisticsInfo();
    const r = new ProtobufReader(data);
    while (!r.eof) {
      const f: Field = r.readField();
      const s: string = (f.bytesValue !== null) ? utf8Decode(f.bytesValue) : '';
      if (f.fieldNumber === 1) { msg.cuid = s; }
      else if (f.fieldNumber === 2) { msg.versionName = s; }
      else if (f.fieldNumber === 3) { msg.versionCode = f.varintValue; }
      else if (f.fieldNumber === 4) { msg.channel = s; }
      else if (f.fieldNumber === 5) { msg.connectCount = f.varintValue; }
      else if (f.fieldNumber === 6) { msg.connectSuccessCount = f.varintValue; }
      else if (f.fieldNumber === 7) { msg.connectTime = f.varintValue; }
      else if (f.fieldNumber === 8) { msg.crashCycle = s; }
    }
    return msg;
  }
}

// ============================================================
// 5. CarlifeAuthenRequest / CarlifeAuthenResponse
//    AuthenRequest:  randomValue=1(string)     车机 → 手机（98376）
//    AuthenResponse: encryptValue=1(string)    手机 → 车机（65609）
//
// 依据车机端反编译 a/a/a/a/m/k/a/c.java:184-233：
//   车机收到 65609 后会先取消 30s「鉴权超时」定时器（hVar.c(this.h)），
//   再判断 `!TextUtils.isEmpty(response.getEncryptValue())`；
//   非空即 z=true（鉴权通过），否则重新计时 5s 再断开。
//   ⚠ 若手机从不发 65609，30s 定时器必然到期 → 打印
//     "Carlife Connect authentication failed." → 断开整条链路。
//     这正是本项目此前「每隔约 30 秒稳定掉线」的根因。
// ============================================================
export class CarlifeAuthenRequest {
  randomValue: string = '';

  constructor(randomValue: string = '') {
    this.randomValue = randomValue;
  }

  static decode(data: Uint8Array): CarlifeAuthenRequest {
    const msg = new CarlifeAuthenRequest();
    const r = new ProtobufReader(data);
    while (!r.eof) {
      const f: Field = r.readField();
      if (f.fieldNumber === 1 && f.bytesValue !== null) {
        msg.randomValue = utf8Decode(f.bytesValue);
      }
    }
    return msg;
  }
}

export class CarlifeAuthenResponse {
  encryptValue: string = '';

  constructor(encryptValue: string = '') {
    this.encryptValue = encryptValue;
  }

  encode(): Uint8Array {
    const w = new ProtobufWriter();
    if (this.encryptValue !== '') {
      w.writeString(1, this.encryptValue);
    }
    return w.toBytes();
  }
}

// ============================================================
// 6. CarlifeAuthenResult
//    authenResult=1(bool)
// ============================================================
export class CarlifeAuthenResult {
  authenResult: boolean = false;

  constructor(authenResult: boolean = false) {
    this.authenResult = authenResult;
  }

  encode(): Uint8Array {
    const w = new ProtobufWriter();
    if (this.authenResult) {
      w.writeBool(1, true);
    }
    return w.toBytes();
  }

  static decode(data: Uint8Array): CarlifeAuthenResult {
    const msg = new CarlifeAuthenResult();
    const r = new ProtobufReader(data);
    while (!r.eof) {
      const f: Field = r.readField();
      if (f.fieldNumber === 1) {
        msg.authenResult = f.varintValue !== 0;
      }
    }
    return msg;
  }
}

// ============================================================
// 6. CarlifeFeatureConfig & CarlifeFeatureConfigList
//    CarlifeFeatureConfig: key=1(string), value=2(int32)
//    CarlifeFeatureConfigList: cnt=1(int32),
//      featureConfig=2(repeated CarlifeFeatureConfig),
//      huBtAudioSupport=3(bool), huBtName=4(string), huBtMAC=5(string)
// ============================================================
export class CarlifeFeatureConfig {
  key: string = '';
  value: number = 0;

  constructor(key: string = '', value: number = 0) {
    this.key = key;
    this.value = value;
  }

  encode(): Uint8Array {
    const w = new ProtobufWriter();
    if (this.key !== '') { w.writeString(1, this.key); }
    if (this.value !== 0) { w.writeInt32(2, this.value); }
    return w.toBytes();
  }

  static decode(data: Uint8Array): CarlifeFeatureConfig {
    const msg = new CarlifeFeatureConfig();
    const r = new ProtobufReader(data);
    while (!r.eof) {
      const f: Field = r.readField();
      if (f.fieldNumber === 1 && f.bytesValue !== null) {
        msg.key = utf8Decode(f.bytesValue);
      } else if (f.fieldNumber === 2) {
        msg.value = f.varintValue;
      }
    }
    return msg;
  }
}

export class CarlifeFeatureConfigList {
  cnt: number = 0;
  featureConfig: CarlifeFeatureConfig[] = [];
  huBtAudioSupport: boolean = false;
  huBtName: string = '';
  huBtMAC: string = '';

  encode(): Uint8Array {
    const w = new ProtobufWriter();
    if (this.cnt !== 0) { w.writeInt32(1, this.cnt); }
    for (let i = 0; i < this.featureConfig.length; i++) {
      w.writeMessage(2, this.featureConfig[i].encode());
    }
    if (this.huBtAudioSupport) { w.writeBool(3, true); }
    if (this.huBtName !== '') { w.writeString(4, this.huBtName); }
    if (this.huBtMAC !== '') { w.writeString(5, this.huBtMAC); }
    return w.toBytes();
  }

  static decode(data: Uint8Array): CarlifeFeatureConfigList {
    const msg = new CarlifeFeatureConfigList();
    const r = new ProtobufReader(data);
    while (!r.eof) {
      const f: Field = r.readField();
      if (f.fieldNumber === 1) {
        msg.cnt = f.varintValue;
      } else if (f.fieldNumber === 2 && f.bytesValue !== null) {
        msg.featureConfig.push(CarlifeFeatureConfig.decode(f.bytesValue));
      } else if (f.fieldNumber === 3) {
        msg.huBtAudioSupport = f.varintValue !== 0;
      } else if (f.fieldNumber === 4 && f.bytesValue !== null) {
        msg.huBtName = utf8Decode(f.bytesValue);
      } else if (f.fieldNumber === 5 && f.bytesValue !== null) {
        msg.huBtMAC = utf8Decode(f.bytesValue);
      }
    }
    return msg;
  }
}

// ============================================================
// 7. CarlifeVideoEncoderInfo
//    width=1(int32), height=2(int32), frameRate=3(int32)
// ============================================================
export class CarlifeVideoEncoderInfo {
  width: number = 0;
  height: number = 0;
  frameRate: number = 0;

  constructor(width: number = 0, height: number = 0, frameRate: number = 0) {
    this.width = width;
    this.height = height;
    this.frameRate = frameRate;
  }

  encode(): Uint8Array {
    const w = new ProtobufWriter();
    if (this.width !== 0) { w.writeInt32(1, this.width); }
    if (this.height !== 0) { w.writeInt32(2, this.height); }
    if (this.frameRate !== 0) { w.writeInt32(3, this.frameRate); }
    return w.toBytes();
  }

  static decode(data: Uint8Array): CarlifeVideoEncoderInfo {
    const msg = new CarlifeVideoEncoderInfo();
    const r = new ProtobufReader(data);
    while (!r.eof) {
      const f: Field = r.readField();
      if (f.fieldNumber === 1) { msg.width = f.varintValue; }
      else if (f.fieldNumber === 2) { msg.height = f.varintValue; }
      else if (f.fieldNumber === 3) { msg.frameRate = f.varintValue; }
    }
    return msg;
  }
}

// ============================================================
// 8. CarlifeTouchAction
//    action=1, x=2, y=3, pointerx=4, pointery=5 (均 int32)
// ============================================================
export class CarlifeTouchAction {
  action: number = 0;
  x: number = 0;
  y: number = 0;
  pointerx: number = 0;
  pointery: number = 0;

  encode(): Uint8Array {
    const w = new ProtobufWriter();
    if (this.action !== 0) { w.writeInt32(1, this.action); }
    if (this.x !== 0) { w.writeInt32(2, this.x); }
    if (this.y !== 0) { w.writeInt32(3, this.y); }
    if (this.pointerx !== 0) { w.writeInt32(4, this.pointerx); }
    if (this.pointery !== 0) { w.writeInt32(5, this.pointery); }
    return w.toBytes();
  }

  static decode(data: Uint8Array): CarlifeTouchAction {
    const msg = new CarlifeTouchAction();
    const r = new ProtobufReader(data);
    while (!r.eof) {
      const f: Field = r.readField();
      if (f.fieldNumber === 1) { msg.action = f.varintValue; }
      else if (f.fieldNumber === 2) { msg.x = f.varintValue; }
      else if (f.fieldNumber === 3) { msg.y = f.varintValue; }
      else if (f.fieldNumber === 4) { msg.pointerx = f.varintValue; }
      else if (f.fieldNumber === 5) { msg.pointery = f.varintValue; }
    }
    return msg;
  }
}

// ============================================================
// 9. CarlifeCarHardKeyCode
//    keycode=1(int32)
// ============================================================
export class CarlifeCarHardKeyCode {
  keycode: number = 0;

  constructor(keycode: number = 0) {
    this.keycode = keycode;
  }

  encode(): Uint8Array {
    const w = new ProtobufWriter();
    if (this.keycode !== 0) { w.writeInt32(1, this.keycode); }
    return w.toBytes();
  }

  static decode(data: Uint8Array): CarlifeCarHardKeyCode {
    const msg = new CarlifeCarHardKeyCode();
    const r = new ProtobufReader(data);
    while (!r.eof) {
      const f: Field = r.readField();
      if (f.fieldNumber === 1) { msg.keycode = f.varintValue; }
    }
    return msg;
  }
}

// ============================================================
// 10. CarlifeMusicInit
//     sampleRate=1, channelConfig=2, sampleFormat=3 (均 int32)
// ============================================================
export class CarlifeMusicInit {
  sampleRate: number = 0;
  channelConfig: number = 0;
  sampleFormat: number = 0;

  encode(): Uint8Array {
    const w = new ProtobufWriter();
    if (this.sampleRate !== 0) { w.writeInt32(1, this.sampleRate); }
    if (this.channelConfig !== 0) { w.writeInt32(2, this.channelConfig); }
    if (this.sampleFormat !== 0) { w.writeInt32(3, this.sampleFormat); }
    return w.toBytes();
  }

  static decode(data: Uint8Array): CarlifeMusicInit {
    const msg = new CarlifeMusicInit();
    const r = new ProtobufReader(data);
    while (!r.eof) {
      const f: Field = r.readField();
      if (f.fieldNumber === 1) { msg.sampleRate = f.varintValue; }
      else if (f.fieldNumber === 2) { msg.channelConfig = f.varintValue; }
      else if (f.fieldNumber === 3) { msg.sampleFormat = f.varintValue; }
    }
    return msg;
  }
}
