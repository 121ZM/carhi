/**
 * 对拍验证脚本（Node 侧）
 *
 * 目的：证明 ArkTS 自研实现与 Python 官方 protobuf 库字节级一致。
 * 做法：把 ArkTS 的协议逻辑等价翻译成 JS（仅剥掉类型标注），
 *       读取 gen_expected.py 生成的基准，逐项比对。
 *
 * 注意：本脚本的逻辑必须与 harmony/.../protocol/*.ets 保持一致。
 *       任何一侧修改，另一侧必须同步。
 *
 * 用法：node tools/verify.mjs
 */

import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));

// ==================== 从 ArkTS 等价翻译的实现 ====================

const CHANNEL_CMD = 1;
const CHANNEL_VIDEO = 2;
const CHANNEL_TOUCH = 6;

const MSG_CMD_MD_INFO = 65540;
const MSG_CMD_MD_HEARTBEAT = 65563;
const MSG_VIDEO_DATA = 131073;
const MSG_TOUCH_ACTION = 425985;

function getHeaderSize(channel) {
  return (channel === CHANNEL_CMD || channel === CHANNEL_TOUCH) ? 8 : 12;
}

function isShortHeaderChannel(channel) {
  return channel === CHANNEL_CMD || channel === CHANNEL_TOUCH;
}

class ProtobufWriter {
  constructor() {
    this.chunks = [];
  }
  writeVarint(value) {
    const out = [];
    let v = value;
    while (v > 0x7F) {
      out.push((v & 0x7F) | 0x80);
      v = v >>> 7;
    }
    out.push(v & 0x7F);
    this.chunks.push(new Uint8Array(out));
  }
  writeTag(fieldNumber, wireType) {
    this.writeVarint((fieldNumber << 3) | wireType);
  }
  writeInt32(fieldNumber, value) {
    this.writeTag(fieldNumber, 0);
    this.writeVarint(value);
  }
  writeBool(fieldNumber, value) {
    this.writeInt32(fieldNumber, value ? 1 : 0);
  }
  writeString(fieldNumber, value) {
    const bytes = utf8Encode(value);
    this.writeTag(fieldNumber, 2);
    this.writeVarint(bytes.length);
    this.chunks.push(bytes);
  }
  writeMessage(fieldNumber, bytes) {
    this.writeTag(fieldNumber, 2);
    this.writeVarint(bytes.length);
    this.chunks.push(bytes);
  }
  toBytes() {
    let total = 0;
    for (const c of this.chunks) total += c.length;
    const out = new Uint8Array(total);
    let offset = 0;
    for (const c of this.chunks) {
      out.set(c, offset);
      offset += c.length;
    }
    return out;
  }
}

function utf8Encode(str) {
  const out = [];
  for (let i = 0; i < str.length; i++) {
    let code = str.charCodeAt(i);
    if (code >= 0xD800 && code <= 0xDBFF && i + 1 < str.length) {
      const next = str.charCodeAt(i + 1);
      if (next >= 0xDC00 && next <= 0xDFFF) {
        code = 0x10000 + ((code - 0xD800) << 10) + (next - 0xDC00);
        i++;
      }
    }
    if (code < 0x80) out.push(code);
    else if (code < 0x800) {
      out.push(0xC0 | (code >> 6));
      out.push(0x80 | (code & 0x3F));
    } else if (code < 0x10000) {
      out.push(0xE0 | (code >> 12));
      out.push(0x80 | ((code >> 6) & 0x3F));
      out.push(0x80 | (code & 0x3F));
    } else {
      out.push(0xF0 | (code >> 18));
      out.push(0x80 | ((code >> 12) & 0x3F));
      out.push(0x80 | ((code >> 6) & 0x3F));
      out.push(0x80 | (code & 0x3F));
    }
  }
  return new Uint8Array(out);
}

// ---------- 消息编码 ----------

function encodeProtocolVersion(major, minor) {
  const w = new ProtobufWriter();
  if (major !== 0) w.writeInt32(1, major);
  if (minor !== 0) w.writeInt32(2, minor);
  return w.toBytes();
}

function encodeMatchStatus(matchStatus, ver) {
  const w = new ProtobufWriter();
  if (matchStatus !== 0) w.writeInt32(1, matchStatus);
  if (ver !== 0) w.writeInt32(2, ver);
  return w.toBytes();
}

function encodeDeviceInfo(d) {
  const w = new ProtobufWriter();
  const strFields = [
    [1, d.os], [2, d.board], [3, d.bootloader], [4, d.brand],
    [5, d.cpuAbi], [6, d.cpuAbi2], [7, d.device], [8, d.display],
    [9, d.fingerprint], [10, d.hardware], [11, d.host], [12, d.cid],
    [13, d.manufacturer], [14, d.model], [15, d.product], [16, d.serial],
    [17, d.codename], [18, d.incremental], [19, d.release], [20, d.sdk]
  ];
  for (const [num, val] of strFields) {
    if (val !== '') w.writeString(num, val);
  }
  if (d.sdkInt !== 0) w.writeInt32(21, d.sdkInt);
  if (d.carlifeversion !== '') w.writeString(22, d.carlifeversion);
  if (d.btaddress !== '') w.writeString(23, d.btaddress);
  return w.toBytes();
}

function encodeStatisticsInfo(s) {
  const w = new ProtobufWriter();
  if (s.cuid !== '') w.writeString(1, s.cuid);
  if (s.versionName !== '') w.writeString(2, s.versionName);
  if (s.versionCode !== 0) w.writeInt32(3, s.versionCode);
  if (s.channel !== '') w.writeString(4, s.channel);
  if (s.connectCount !== 0) w.writeInt32(5, s.connectCount);
  if (s.connectSuccessCount !== 0) w.writeInt32(6, s.connectSuccessCount);
  if (s.connectTime !== 0) w.writeInt32(7, s.connectTime);
  if (s.crashCycle !== '') w.writeString(8, s.crashCycle);
  return w.toBytes();
}

function encodeAuthenResult(v) {
  const w = new ProtobufWriter();
  if (v) w.writeBool(1, true);
  return w.toBytes();
}

function encodeFeatureConfigList(list) {
  const w = new ProtobufWriter();
  if (list.cnt !== 0) w.writeInt32(1, list.cnt);
  for (const fc of list.featureConfig) {
    const sub = new ProtobufWriter();
    if (fc.key !== '') sub.writeString(1, fc.key);
    if (fc.value !== 0) sub.writeInt32(2, fc.value);
    w.writeMessage(2, sub.toBytes());
  }
  if (list.huBtAudioSupport) w.writeBool(3, true);
  if (list.huBtName !== '') w.writeString(4, list.huBtName);
  if (list.huBtMAC !== '') w.writeString(5, list.huBtMAC);
  return w.toBytes();
}

function encodeVideoEncoderInfo(width, height, frameRate) {
  const w = new ProtobufWriter();
  if (width !== 0) w.writeInt32(1, width);
  if (height !== 0) w.writeInt32(2, height);
  if (frameRate !== 0) w.writeInt32(3, frameRate);
  return w.toBytes();
}

function encodeTouchAction(t) {
  const w = new ProtobufWriter();
  if (t.action !== 0) w.writeInt32(1, t.action);
  if (t.x !== 0) w.writeInt32(2, t.x);
  if (t.y !== 0) w.writeInt32(3, t.y);
  if (t.pointerx !== 0) w.writeInt32(4, t.pointerx);
  if (t.pointery !== 0) w.writeInt32(5, t.pointery);
  return w.toBytes();
}

function encodeHardKeyCode(k) {
  const w = new ProtobufWriter();
  if (k !== 0) w.writeInt32(1, k);
  return w.toBytes();
}

function encodeMusicInit(sampleRate, channelConfig, sampleFormat) {
  const w = new ProtobufWriter();
  if (sampleRate !== 0) w.writeInt32(1, sampleRate);
  if (channelConfig !== 0) w.writeInt32(2, channelConfig);
  if (sampleFormat !== 0) w.writeInt32(3, sampleFormat);
  return w.toBytes();
}

// ---------- 报文封包 ----------

function packMessage(channel, serviceType, payload, seqOrTs = 0) {
  const payloadLen = payload.length;
  const headerSize = getHeaderSize(channel);
  const out = new Uint8Array(headerSize + payloadLen);
  const view = new DataView(out.buffer);
  if (isShortHeaderChannel(channel)) {
    view.setUint16(0, payloadLen, false);
    view.setUint16(2, 0, false);
    view.setUint32(4, serviceType, false);
  } else {
    view.setUint32(0, payloadLen, false);
    view.setUint32(4, seqOrTs, false);
    view.setUint32(8, serviceType, false);
  }
  if (payloadLen > 0) out.set(payload, headerSize);
  return out;
}

// ==================== 对拍 ====================

const expected = JSON.parse(readFileSync(join(__dirname, 'expected.json'), 'utf8'));

let pass = 0;
let fail = 0;
const failures = [];

function check(name, actual) {
  const exp = expected[name];
  if (!exp) {
    console.log(`  [SKIP] ${name} —— 基准中无此项`);
    return;
  }
  const a = Array.from(actual);
  if (a.length === exp.length && a.every((v, i) => v === exp[i])) {
    console.log(`  [PASS] ${name}  (${a.length} bytes)`);
    pass++;
  } else {
    console.log(`  [FAIL] ${name}`);
    console.log(`         期望: ${exp.join(',')}`);
    console.log(`         实际: ${a.join(',')}`);
    fail++;
    failures.push(name);
  }
}

function toHex(bytes) {
  return Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join(' ');
}

console.log('\n===== CarLife 协议层对拍验证 =====\n');
console.log('--- 1. 消息编码 ---');
check('CarlifeProtocolVersion', encodeProtocolVersion(4, 0));
check('CarlifeProtocolVersionMatchStatus', encodeMatchStatus(1, 4));
check('CarlifeDeviceInfo', encodeDeviceInfo({
  os: "HarmonyOS", board: "ALN-AL00", bootloader: "unknown", brand: "HUAWEI",
  cpuAbi: "arm64-v8a", cpuAbi2: "armeabi-v7a", device: "ALN-AL00",
  display: "1260x2720",
  fingerprint: "HUAWEI/ALN-AL00/ALN-AL00:12/HUAWEIALN-AL00/1:user/release-keys",
  hardware: "kirin9000s", host: "huawei-build", cid: "HUAWEIALN-AL00",
  manufacturer: "HUAWEI", model: "ALN-AL00", product: "ALN-AL00", serial: "unknown",
  codename: "REL", incremental: "1", release: "12", sdk: "12", sdkInt: 12,
  carlifeversion: "8.4.0", btaddress: "AA:BB:CC:DD:EE:FF"
}));
check('CarlifeStatisticsInfo', encodeStatisticsInfo({
  cuid: "12345678", versionName: "8.4.0", versionCode: 16, channel: "20029999",
  connectCount: 1, connectSuccessCount: 1, connectTime: 1234, crashCycle: ""
}));
check('CarlifeAuthenResult_true', encodeAuthenResult(true));
check('CarlifeAuthenResult_unset', encodeAuthenResult(false));
check('CarlifeFeatureConfigList', encodeFeatureConfigList({
  cnt: 3, huBtAudioSupport: false, huBtName: "CarLife_Phone", huBtMAC: "AA:BB:CC:DD:EE:FF",
  featureConfig: [
    { key: "USB_MTU", value: 16384 },
    { key: "I_FRAME_INTERVAL", value: 300 },
    { key: "CONNECT_TYPE", value: 2 }
  ]
}));
check('CarlifeVideoEncoderInfo', encodeVideoEncoderInfo(1280, 720, 30));
check('CarlifeTouchAction', encodeTouchAction({ action: 0, x: 640, y: 360, pointerx: 640, pointery: 360 }));
check('CarlifeCarHardKeyCode', encodeHardKeyCode(1));
check('CarlifeMusicInit', encodeMusicInit(48000, 2, 2));
check('CarlifeVideoEncoderInfo_1080p60', encodeVideoEncoderInfo(1920, 1080, 60));

console.log('\n--- 2. 报文封包（头长度差异）---');
const devBytes = encodeDeviceInfo({
  os: "HarmonyOS", board: "ALN-AL00", bootloader: "unknown", brand: "HUAWEI",
  cpuAbi: "arm64-v8a", cpuAbi2: "armeabi-v7a", device: "ALN-AL00",
  display: "1260x2720",
  fingerprint: "HUAWEI/ALN-AL00/ALN-AL00:12/HUAWEIALN-AL00/1:user/release-keys",
  hardware: "kirin9000s", host: "huawei-build", cid: "HUAWEIALN-AL00",
  manufacturer: "HUAWEI", model: "ALN-AL00", product: "ALN-AL00", serial: "unknown",
  codename: "REL", incremental: "1", release: "12", sdk: "12", sdkInt: 12,
  carlifeversion: "8.4.0", btaddress: "AA:BB:CC:DD:EE:FF"
});
check('FRAME_ch1_MD_INFO', packMessage(CHANNEL_CMD, MSG_CMD_MD_INFO, devBytes));
check('FRAME_ch1_heartbeat_empty', packMessage(CHANNEL_CMD, MSG_CMD_MD_HEARTBEAT, new Uint8Array(0)));
check('FRAME_ch2_video', packMessage(CHANNEL_VIDEO, MSG_VIDEO_DATA,
  new Uint8Array([0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0x00, 0x1E]), 42));
check('FRAME_ch6_touch', packMessage(CHANNEL_TOUCH, MSG_TOUCH_ACTION,
  encodeTouchAction({ action: 0, x: 640, y: 360, pointerx: 640, pointery: 360 })));

console.log('\n===== 结果 =====');
console.log(`  通过: ${pass}   失败: ${fail}`);
if (fail > 0) {
  console.log(`  失败项: ${failures.join(', ')}`);
  process.exit(1);
}
console.log('  全部字节级一致\n');
