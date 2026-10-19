#!/usr/bin/env python3
"""
模拟车机（HU）—— 带**官方 proto 一致性校验**的版本。

用途：在没有真实车机的情况下驱动手机端 CarLife 实现走完整流程，
     并**按官方协议定义逐字段校验手机端的回包**。

权威依据：`refs/carlife_proto/*.proto`
  从官方手机端 App（`bdc_16031.apk`）里原样提取的 93 个 `.proto`，
  是**线格式的权威定义**（比任何逆向结论都准）。
  本脚本只按这些定义编解码，不自己发明字段。

与旧版的区别（旧版有多处与官方 proto 不符，已修）：
  1. `98376 HU_AUTHEN_REQUEST` 旧版发**空 payload**；
     官方 `CarlifeAuthenRequest { required string randomValue = 1; }` —— **randomValue 必填**。
  2. `98386 HU_FEATURE_CONFIG_RESPONSE` 旧版发 `\\x08\\x01`（按 int 编）；
     官方 `CarlifeFeatureConfig { required string key; required int32 value; }` —— key 是**字符串**。
  3. `98343 HU_STATISTICAL_INFO` 旧版发两个 int；
     官方 `CarlifeStatisticsInfo` 的 1/2/4 字段都是**字符串**且**全部 required**。
  4. `NAMES` 表缺 **65609 MD_AUTHEN_RESPONSE** —— 而这正是本项目历史上
     「每隔 30~62 秒稳定掉线」的根因所在（车机端 30 秒鉴权定时器
     **只有收到非空 encryptValue 才会取消**）。现列为**关键校验项**。

报文格式（全大端序）：
  Ch1/Ch6 (8 字节头)：[uint16 len][uint16 reserved][uint32 service_type] + payload
  其它通道 (12 字节头)：[uint32 len][uint32 seq_or_ts][uint32 service_type] + payload

音频校验（2026-10-16 加）：AUDIO(9240) 上核对 MEDIA_INIT(CarlifeMusicInit 字段)
  + MEDIA_DATA(PCM) 的顺序与帧大小。注意：若手机当时没有音频播放，
  内录采集不产 buffer，INIT/DATA 都不会来 —— 这属正常（只告警不判失败）。

用法：
  python tools/mock_hu.py --host 192.168.0.186 --duration 20
  python tools/mock_hu.py --host 192.168.0.186 --strict    # 有校验失败则退出码非 0
"""

import argparse
import socket
import struct
import sys
import threading
import time

# ───────────────────────── 消息 ID ─────────────────────────

# 车机 -> 手机
HU_PROTOCOL_VERSION = 98305
HU_STATISTICAL_INFO = 98343
HU_INFO = 98307
HU_AUTHEN_REQUEST = 98376
HU_VIDEO_ENCODER_INIT = 98311
HU_FEATURE_CONFIG_RESPONSE = 98386
VIDEO_ENCODER_START = 98313
VIDEO_ENCODER_PAUSE = 98314
VIDEO_ENCODER_RESET = 98315
VIDEO_FRAME_RATE_CHANGE = 98316
VIDEO_HEARTBEAT = 131074

# 手机 -> 车机
MD_PROTOCOL_VERSION_MATCH_STATUS = 65538
MD_INFO = 65540
MD_AUTHEN_RESPONSE = 65609
MD_AUTHEN_RESULT = 65611
MD_FEATURE_CONFIG_LIST = 65617
MD_VIDEO_ENCODER_INIT = 65544
MD_VIDEO_FRAME_RATE = 65549
MD_VIDEO_ENCODER_INIT_DONE = 65551
MD_FOREGROUND = 65563
VIDEO_DATA = 131073

# 媒体音频（Ch3/9240）—— 手机 -> 车机
# ★ 数值按官方两个来源核对（2026-10-16）：
#   - 官方 Android 车机端 CommonParams.java（Apollo-DuerOS/CarLife-Android-Vehicle）
#   - 官方跨平台 C++ 车机库 CTranRecvPackageProcess.h（CarLife-Vehicle-Lib）
# 两者一致：INIT=0x30001 / STOP=0x30002 / PAUSE=0x30003 /
#           RESUME_PLAY=0x30004 / SEEK_TO=0x30005 / DATA=0x30006。
# ⚠️ 本仓库 ArkTS 侧 Constants.ets 曾把 DATA/STOP 写反，已按此修正。
MEDIA_INIT = 0x00030001     # 196609 CarlifeMusicInit
MEDIA_STOP = 0x00030002     # 196610
MEDIA_PAUSE = 0x00030003    # 196611
MEDIA_RESUME_PLAY = 0x00030004   # 196612
MEDIA_SEEK_TO = 0x00030005  # 196613
MEDIA_DATA = 0x00030006     # 196614 PCM 裸流

NAMES = {
    HU_PROTOCOL_VERSION: "HU_PROTOCOL_VERSION",
    HU_STATISTICAL_INFO: "HU_STATISTICAL_INFO",
    HU_INFO: "HU_INFO",
    HU_AUTHEN_REQUEST: "HU_AUTHEN_REQUEST",
    HU_VIDEO_ENCODER_INIT: "HU_VIDEO_ENCODER_INIT",
    HU_FEATURE_CONFIG_RESPONSE: "HU_FEATURE_CONFIG_RESPONSE",
    VIDEO_ENCODER_START: "VIDEO_ENCODER_START",
    VIDEO_ENCODER_PAUSE: "VIDEO_ENCODER_PAUSE",
    VIDEO_ENCODER_RESET: "VIDEO_ENCODER_RESET",
    VIDEO_FRAME_RATE_CHANGE: "VIDEO_FRAME_RATE_CHANGE",
    VIDEO_HEARTBEAT: "VIDEO_HEARTBEAT",
    MD_PROTOCOL_VERSION_MATCH_STATUS: "MD_PROTOCOL_VERSION_MATCH_STATUS",
    MD_INFO: "MD_INFO",
    MD_AUTHEN_RESPONSE: "MD_AUTHEN_RESPONSE",
    MD_AUTHEN_RESULT: "MD_AUTHEN_RESULT",
    MD_FEATURE_CONFIG_LIST: "MD_FEATURE_CONFIG_LIST",
    MD_VIDEO_ENCODER_INIT: "MD_VIDEO_ENCODER_INIT",
    MD_VIDEO_FRAME_RATE: "MD_VIDEO_FRAME_RATE",
    MD_VIDEO_ENCODER_INIT_DONE: "MD_VIDEO_ENCODER_INIT_DONE",
    MD_FOREGROUND: "MD_FOREGROUND",
    VIDEO_DATA: "VIDEO_DATA",
    MEDIA_INIT: "MEDIA_INIT",
    MEDIA_STOP: "MEDIA_STOP",
    MEDIA_PAUSE: "MEDIA_PAUSE",
    MEDIA_RESUME_PLAY: "MEDIA_RESUME_PLAY",
    MEDIA_SEEK_TO: "MEDIA_SEEK_TO",
    MEDIA_DATA: "MEDIA_DATA",
}

# ─────────────── 官方 proto 字段表（照 refs/carlife_proto 抄） ───────────────
# 值：(消息名, {字段号: (字段名, 类型)})  类型 ∈ {int, bool, string, bytes, msg}
SCHEMAS = {
    MD_PROTOCOL_VERSION_MATCH_STATUS: ("CarlifeProtocolVersionMatchStatus", {
        1: ("matchStatus", "int"),
        2: ("carlifeProtocolVersion", "int"),
    }),
    MD_INFO: ("CarlifeDeviceInfo", {
        1: ("os", "string"), 2: ("board", "string"), 3: ("bootloader", "string"),
        4: ("brand", "string"), 5: ("cpu_abi", "string"), 6: ("cpu_abi2", "string"),
        7: ("device", "string"), 8: ("display", "string"), 9: ("fingerprint", "string"),
        10: ("hardware", "string"), 11: ("host", "string"), 12: ("cid", "string"),
        13: ("manufacturer", "string"), 14: ("model", "string"), 15: ("product", "string"),
        16: ("serial", "string"), 17: ("codename", "string"), 18: ("incremental", "string"),
        19: ("release", "string"), 20: ("sdk", "string"), 21: ("sdk_int", "int"),
        22: ("token", "string"), 23: ("btaddress", "string"), 24: ("carlifeversion", "string"),
        25: ("carlifeType", "int"), 26: ("year", "string"), 27: ("carlifeSdkInt", "int"),
    }),
    MD_AUTHEN_RESPONSE: ("CarlifeAuthenResponse", {
        1: ("encryptValue", "string"),
    }),
    MD_AUTHEN_RESULT: ("CarlifeAuthenResult", {
        1: ("authenResult", "bool"),
    }),
    MD_FEATURE_CONFIG_LIST: ("CarlifeFeatureConfigList", {
        1: ("cnt", "int"),
        2: ("featureConfig", "msg"),
        3: ("huBtAudioSupport", "bool"),
        4: ("huBtName", "string"),
        5: ("huBtMAC", "string"),
    }),
    MD_VIDEO_ENCODER_INIT: ("CarlifeVideoEncoderInfo", {
        1: ("width", "int"), 2: ("height", "int"), 3: ("frameRate", "int"),
        4: ("saveAreaWidth", "int"), 5: ("saveAreaHeight", "int"),
        6: ("saveAreaX", "int"), 7: ("saveAreaY", "int"),
        8: ("drawUIOutsideSafeArea", "bool"), 9: ("needAdapterScreen", "bool"),
    }),
    MD_VIDEO_ENCODER_INIT_DONE: ("(无独立 proto，空体或简单体)", {}),
    MD_VIDEO_FRAME_RATE: ("CarlifeVideoFrameRate", {1: ("frameRate", "int")}),
    MD_FOREGROUND: ("(无独立 proto)", {}),
    # CarlifeMusicInitProto.proto：sampleRate=1, channelConfig=2, sampleFormat=3（均 required int32）
    MEDIA_INIT: ("CarlifeMusicInit", {
        1: ("sampleRate", "int"),
        2: ("channelConfig", "int"),
        3: ("sampleFormat", "int"),
    }),
}


# ───────────────────────── protobuf 编解码 ─────────────────────────

def varint(v: int) -> bytes:
    out = bytearray()
    while True:
        b = v & 0x7F
        v >>= 7
        if v:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def pb_int(field: int, value: int) -> bytes:
    """protobuf: 字段号 + varint（wire type 0）"""
    return varint((field << 3) | 0) + varint(value)


def pb_bytes(field: int, data: bytes) -> bytes:
    """protobuf: 字段号 + length-delimited（wire type 2）"""
    return varint((field << 3) | 2) + varint(len(data)) + data


def _read_varint(data: bytes, i: int):
    shift = 0
    val = 0
    while i < len(data):
        b = data[i]
        i += 1
        val |= (b & 0x7F) << shift
        if not (b & 0x80):
            return val, i
        shift += 7
        if shift > 63:
            return None, i
    return None, i


def pb_decode(data: bytes) -> list:
    """通用 protobuf 解码 -> [(字段号, wire_type, 值)]；值：wt0=int, wt2=bytes, wt5/1=定长"""
    out = []
    i = 0
    n = len(data)
    while i < n:
        key, i = _read_varint(data, i)
        if key is None:
            break
        fno, wt = key >> 3, key & 7
        if fno == 0:
            break
        if wt == 0:
            v, i = _read_varint(data, i)
            if v is None:
                break
            out.append((fno, wt, v))
        elif wt == 2:
            ln, i = _read_varint(data, i)
            if ln is None or i + ln > n:
                break
            out.append((fno, wt, data[i:i + ln]))
            i += ln
        elif wt == 5:
            if i + 4 > n:
                break
            out.append((fno, wt, struct.unpack("<I", data[i:i + 4])[0]))
            i += 4
        elif wt == 1:
            if i + 8 > n:
                break
            out.append((fno, wt, struct.unpack("<Q", data[i:i + 8])[0]))
            i += 8
        else:
            break  # 未知 wire type，放弃（避免误读）
    return out


def pb_to_dict(data: bytes, service_type: int) -> dict:
    """按 SCHEMAS 把 payload 解成 {字段名: 值}"""
    schema = SCHEMAS.get(service_type)
    if not schema:
        return {}
    _, fields = schema
    out = {}
    for fno, wt, val in pb_decode(data):
        meta = fields.get(fno)
        if not meta:
            out[f"#{fno}"] = val
            continue
        name, typ = meta
        if typ in ("string", "bytes") and isinstance(val, (bytes, bytearray)):
            try:
                out[name] = val.decode("utf-8")
            except UnicodeDecodeError:
                out[name] = f"<{len(val)}B 非 UTF-8>"
        elif typ == "msg" and isinstance(val, (bytes, bytearray)):
            out[name] = pb_to_dict(val, -1) if False else f"<{len(val)}B>"
        else:
            out[name] = val
    return out


# ───────────────────────── 通道封装 ─────────────────────────

class Channel:
    """单个通道的客户端封装，带后台读取线程"""

    def __init__(self, host: str, port: int, channel: int, label: str):
        self.host, self.port, self.channel, self.label = host, port, channel, label
        self.sock = None
        self.alive = False
        self.rx_bytes = 0
        self.rx_msgs = []          # [(service_type, payload_bytes, recv_time)]
        self._lock = threading.Lock()

    def connect(self) -> bool:
        try:
            self.sock = socket.create_connection((self.host, self.port), timeout=5)
            self.sock.settimeout(0.3)
            self.alive = True
            print(f"[{self.label}] 已连接 {self.host}:{self.port}")
            threading.Thread(target=self._reader, daemon=True).start()
            return True
        except OSError as e:
            print(f"[{self.label}] 连接失败 -> {e}")
            return False

    def _reader(self) -> None:
        buf = bytearray()
        hdr = 8 if self.channel in (1, 6) else 12
        while self.alive and self.sock:
            try:
                chunk = self.sock.recv(1 << 20)
                if not chunk:
                    print(f"[{self.label}] 对端关闭连接")
                    self.alive = False
                    break
                buf.extend(chunk)
                self.rx_bytes += len(chunk)
                while len(buf) >= hdr:
                    if hdr == 8:
                        plen, _, stype = struct.unpack(">HHI", bytes(buf[:8]))
                    else:
                        plen, _, stype = struct.unpack(">III", bytes(buf[:12]))
                    if len(buf) < hdr + plen:
                        break
                    payload = bytes(buf[hdr:hdr + plen])
                    del buf[:hdr + plen]
                    with self._lock:
                        self.rx_msgs.append((stype, payload, time.time()))
                    if stype != VIDEO_DATA:   # 视频帧太密，不逐条打印
                        print(f"[{self.label}] <- {NAMES.get(stype, hex(stype))}"
                              f" (ID={stype}, len={plen})")
            except socket.timeout:
                continue
            except OSError:
                if self.alive:
                    print(f"[{self.label}] 读取异常")
                break

    def send(self, service_type: int, payload: bytes = b"") -> None:
        if not self.sock or not self.alive:
            return
        try:
            self.sock.sendall(pack(self.channel, service_type, payload))
            print(f"[{self.label}] -> {NAMES.get(service_type, hex(service_type))}"
                  f" (ID={service_type}, len={len(payload)})")
        except OSError as e:
            print(f"[{self.label}] 发送失败 -> {e}")
            self.alive = False

    def wait_for(self, service_type: int, timeout: float):
        """等某类回包，返回 payload（或 None）"""
        end = time.time() + timeout
        while time.time() < end:
            with self._lock:
                for st, pl, _t in self.rx_msgs:
                    if st == service_type:
                        return pl
            time.sleep(0.05)
        return None

    def close(self) -> None:
        self.alive = False
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass


def pack(channel: int, service_type: int, payload: bytes = b"", seq: int = 0) -> bytes:
    if channel in (1, 6):
        return struct.pack(">HHI", len(payload), 0, service_type) + payload
    return struct.pack(">III", len(payload), seq, service_type) + payload


# ───────────────────────── 校验 ─────────────────────────

class Report:
    def __init__(self):
        self.items = []      # (级别, 标题, 详情)  级别 ∈ {PASS, FAIL, WARN}

    def add(self, level: str, title: str, detail: str = "") -> None:
        self.items.append((level, title, detail))

    def check(self, cond: bool, title: str, detail: str = "", warn_only: bool = False) -> bool:
        self.add("PASS" if cond else ("WARN" if warn_only else "FAIL"), title, detail)
        return cond

    def dump(self) -> int:
        fails = sum(1 for lv, _, _ in self.items if lv == "FAIL")
        warns = sum(1 for lv, _, _ in self.items if lv == "WARN")
        print("\n" + "=" * 66)
        print("  官方 proto 一致性校验结果")
        print("=" * 66)
        for lv, title, detail in self.items:
            mark = {"PASS": "  OK ", "FAIL": "FAIL ", "WARN": "WARN "}[lv]
            print(f"[{mark}] {title}")
            if detail:
                print(f"         {detail}")
        print("-" * 66)
        print(f"  通过 {len(self.items) - fails - warns} / 失败 {fails} / 警告 {warns}")
        print("=" * 66)
        return fails


def show(name: str, d: dict, keys) -> str:
    parts = []
    for k in keys:
        if k in d:
            v = d[k]
            if isinstance(v, str) and len(v) > 40:
                v = v[:37] + "..."
            parts.append(f"{k}={v!r}")
    return ", ".join(parts) if parts else "(无字段)"


# ───────────────────────── 主流程 ─────────────────────────

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--cmd-port", type=int, default=7240)
    ap.add_argument("--video-port", type=int, default=8240)
    ap.add_argument("--width", type=int, default=1280)
    ap.add_argument("--height", type=int, default=720)
    ap.add_argument("--fps", type=int, default=30)
    ap.add_argument("--hb-hz", type=float, default=5.0, help="心跳频率 次/秒")
    ap.add_argument("--duration", type=int, default=20)
    ap.add_argument("--skip-handshake", action="store_true")
    ap.add_argument("--strict", action="store_true", help="有 FAIL 时退出码非 0")
    # ★ 2026-10-13 新增：补齐 7 条通道。
    #   旧版只连 CMD(7240)+VIDEO(8240)，导致「全通过」其实只覆盖 2/7 条通道，
    #   AUDIO/TTS/VR/TOUCH/DATA 五条从未被验证过。默认现在全连。
    ap.add_argument("--no-extra-channels", action="store_true",
                    help="退回旧行为：只连 CMD/VIDEO 两条")
    ap.add_argument("--no-touch-probe", action="store_true",
                    help="不向 TOUCH(9340) 下发触控事件")
    args = ap.parse_args()

    rep = Report()

    cmd = Channel(args.host, args.cmd_port, 1, "CMD")
    if not cmd.connect():
        print("控制通道连不上 —— 手机上 CarHi 的服务起了吗？端口监听了吗？")
        return 2

    if not args.skip_handshake:
        # ── 1. 98305 版本协商 ──
        cmd.send(HU_PROTOCOL_VERSION, pb_int(1, 4) + pb_int(2, 1))
        pl = cmd.wait_for(MD_PROTOCOL_VERSION_MATCH_STATUS, 3.0)
        if rep.check(pl is not None, "收到 65538 MD_PROTOCOL_VERSION_MATCH_STATUS"):
            d = pb_to_dict(pl, MD_PROTOCOL_VERSION_MATCH_STATUS)
            rep.check(d.get("matchStatus") == 1, "65538.matchStatus == 1（版本匹配）",
                      show("MatchStatus", d, ["matchStatus", "carlifeProtocolVersion"]))
            rep.check("carlifeProtocolVersion" in d, "65538 带 carlifeProtocolVersion 字段",
                      show("MatchStatus", d, ["carlifeProtocolVersion"]), warn_only=True)

        # ── 2. 65540 设备信息（应主动发，不等后续） ──
        pl = cmd.wait_for(MD_INFO, 3.0)
        if rep.check(pl is not None, "收到 65540 MD_INFO（手机设备信息）"):
            d = pb_to_dict(pl, MD_INFO)
            rep.check(bool(d.get("model") or d.get("os")), "65540 至少带 model/os",
                      show("DeviceInfo", d, ["os", "model", "brand", "sdk_int",
                                             "carlifeversion", "carlifeSdkInt", "btaddress"]))
            # ★ 官方 CarlifeDeviceInfoProto.proto 原文：
            #       optional string token          = 22;
            #       optional string carlifeversion = 24;
            #   本项目曾把 carlifeversion 写在 22（= 车机的 token 位），现已修正。
            rep.check("carlifeversion" in d, "★ 65540 带 carlifeversion（字段 24）",
                      show("DeviceInfo", d, ["carlifeversion"]))
            rep.check("token" not in d, "65540 未把版本号塞进 token（字段 22）",
                      show("DeviceInfo", d, ["token"]), warn_only=True)

        # ── 3. 98343 统计信息（字段 1/2/4 都是 required string） ──
        cmd.send(HU_STATISTICAL_INFO,
                 pb_bytes(1, b"mockcuid") + pb_bytes(2, b"mock-hu") + pb_int(3, 1)
                 + pb_bytes(4, b"mock") + pb_int(5, 1) + pb_int(6, 1) + pb_int(7, 0))
        time.sleep(0.3)

        # ── 4. 98307 设备信息（异步，手机端只记录） ──
        cmd.send(HU_INFO, pb_bytes(1, b"samsung") + pb_bytes(2, b"SM-N9860")
                 + pb_bytes(3, b"TQ2A.230505.002 release-keys"))
        time.sleep(0.2)

        # ── 5. 98376 鉴权请求：randomValue 是 required！ ──
        # 车机端收到手机的 65540 后会起 30 秒定时器，
        # 只有收到**非空 encryptValue 的 65609** 才取消 → 这是历史掉线根因。
        cmd.send(HU_AUTHEN_REQUEST, pb_bytes(1, b"2.0;1750000000"))
        pl = cmd.wait_for(MD_AUTHEN_RESPONSE, 5.0)
        if rep.check(pl is not None, "★ 收到 65609 MD_AUTHEN_RESPONSE（鉴权响应）"):
            d = pb_to_dict(pl, MD_AUTHEN_RESPONSE)
            ev = d.get("encryptValue", "")
            rep.check(bool(ev), "★ 65609.encryptValue **非空**（车机 30s 定时器的唯一取消条件）",
                      f"encryptValue={ev!r} (len={len(ev) if isinstance(ev, str) else 0})")
        pl = cmd.wait_for(MD_AUTHEN_RESULT, 5.0)
        if rep.check(pl is not None, "收到 65611 MD_AUTHEN_RESULT（鉴权结果）"):
            d = pb_to_dict(pl, MD_AUTHEN_RESULT)
            rep.check(bool(d.get("authenResult")), "65611.authenResult == true",
                      show("AuthenResult", d, ["authenResult"]))

        # ── 6. 65617 特征配置请求 ──
        # 方向是 MD→HU，语义是「请把你的 FeatureConfig 发给我」。
        # 官方 CarlifeFeatureConfigList 里带的是 huBtAudioSupport/huBtName/huBtMAC
        # —— 全是 HU 侧字段，所以这个 proto 属于 **98386（HU→MD 响应）**，
        # 不属于请求。请求体为空因此是合理的；只有真带了 body 才校验 cnt。
        pl = cmd.wait_for(MD_FEATURE_CONFIG_LIST, 3.0)
        if rep.check(pl is not None, "收到 65617 MD_FEATURE_CONFIG_REQUEST"):
            if not pl:
                rep.add("PASS", "65617 请求体为空（纯请求，无 body；与官方行为一致）")
            else:
                d = pb_to_dict(pl, MD_FEATURE_CONFIG_LIST)
                rep.check("cnt" in d, "65617 带 cnt", show("FeatureConfigList", d, ["cnt"]))
        # 回一个空的 FeatureConfigList（cnt=0）
        cmd.send(HU_FEATURE_CONFIG_RESPONSE, pb_int(1, 0))
        time.sleep(0.2)

        # ── 7. 98311 编码参数 → 65544 ──
        cmd.send(HU_VIDEO_ENCODER_INIT,
                 pb_int(1, args.width) + pb_int(2, args.height) + pb_int(3, args.fps))
        pl = cmd.wait_for(MD_VIDEO_ENCODER_INIT, 5.0)
        if rep.check(pl is not None, "收到 65544 MD_VIDEO_ENCODER_INIT（编码参数）"):
            d = pb_to_dict(pl, MD_VIDEO_ENCODER_INIT)
            rep.check("width" in d and "height" in d and "frameRate" in d,
                      "65544 带 width/height/frameRate",
                      show("VideoEncoderInfo", d,
                           ["width", "height", "frameRate", "needAdapterScreen"]))

        # ── 8. 98313 开始推流 ──
        cmd.send(VIDEO_ENCODER_START, b"")

    # ── 9. 视频通道：发心跳 + 收 131073 ──
    video = Channel(args.host, args.video_port, 2, "VIDEO")
    video_ok = video.connect()
    rep.check(video_ok, "VIDEO(8240) 通道可连接")

    # ── 9b. ★ 补齐其余 5 条通道 ──
    # 旧版只连 CMD+VIDEO，于是"全通过"其实只覆盖 2/7 条通道；
    # AUDIO/TTS/VR/TOUCH/DATA 从未被验证。这里全部连上，至少验证：
    #   ① 端口真在 LISTEN 且能 accept；② 手机端不再把入站数据静默丢弃。
    TOUCH_ACTION = 425985          # 0x00068001 CarlifeTouchAction（Ch6 触控通道）
    extra = []
    if not args.no_extra_channels:
        for ch, port, label in ((3, 9240, "AUDIO"), (4, 9241, "TTS"),
                                (5, 9242, "VR"), (6, 9340, "TOUCH"),
                                (7, 9440, "DATA")):
            c = Channel(args.host, port, ch, label)
            ok = c.connect()
            rep.check(ok, f"{label}({port}) 通道可连接")
            if ok:
                extra.append(c)

    # ── 9c. 触控探测：经 TOUCH(9340) 下发 CarlifeTouchAction ──
    # 官方 proto：CarlifeTouchAction { required int32 action=1; x=2; y=3; ... }
    # 若手机端仍像旧版那样"读进来就丢"，手机上不会出现 [通道6] 日志。
    touch = next((c for c in extra if c.label == "TOUCH"), None)
    if touch is not None and not args.no_touch_probe:
        for act, tx, ty in ((0, 320, 240), (1, 320, 240)):
            touch.send(TOUCH_ACTION, pb_int(1, act) + pb_int(2, tx) + pb_int(3, ty))
            time.sleep(0.15)
        print("[TOUCH] 已下发 DOWN/UP 各 1 次（action=0/1, x=320, y=240）")

    interval = 1.0 / args.hb_hz if args.hb_hz > 0 else 0.2
    deadline = time.time() + args.duration
    sent = 0
    last = time.time()
    last_hb_at = time.time()      # 最近一次 VIDEO 心跳的发送时刻（判 MEDIA_STOP 归属用）
    alive_at_end = {}             # 心跳循环退出瞬间的各通道存活快照（拆链前一刻）
    stopped_by_disconnect = False
    print(f"[INFO] 心跳 131074 @ {args.hb_hz}/s，持续 {args.duration}s")

    try:
        while time.time() < deadline and cmd.alive:
            video.send(VIDEO_HEARTBEAT)
            sent += 1
            last_hb_at = time.time()
            now = time.time()
            if now - last >= 10.0:
                with video._lock:
                    n_v = len(video.rx_msgs)
                print(f"[STAT] 心跳 {sent} 次 | VIDEO 收 {video.rx_bytes}B/{n_v}条"
                      f" | CMD 收 {cmd.rx_bytes}B | alive cmd={cmd.alive} video={video.alive}")
                last = now
            time.sleep(interval)
        stopped_by_disconnect = not cmd.alive
        # ★ 快照必须赶在 finally 的 sleep 之前：mock 停止心跳后手机/代理会在
        #   极短时间内拆链，等 0.3s 再取 alive 会把正常的拆链时序误判成掉线。
        alive_at_end = {c.label: c.alive for c in [cmd, video] + extra}
    except KeyboardInterrupt:
        print("\n[INFO] 中断")
    finally:
        time.sleep(0.3)

    # ── 10. 推流校验 ──
    with video._lock:
        vmsgs = list(video.rx_msgs)
    with cmd._lock:
        cmsgs = list(cmd.rx_msgs)

    frames = [pl for st, pl, _t in vmsgs if st == VIDEO_DATA]
    rep.check(len(frames) > 0, f"VIDEO(8240) 收到 {VIDEO_DATA} 视频帧", f"共 {len(frames)} 帧")
    if frames:
        sizes = sorted(len(f) for f in frames)
        rep.check(sizes[-1] > 1000, "视频帧大小合理（>1KB）",
                  f"最小 {sizes[0]}B / 中位 {sizes[len(sizes)//2]}B / 最大 {sizes[-1]}B")
        # H.264 Annex-B：找起始码 00 00 00 01 或 00 00 01
        joined = b"".join(frames[:20])
        rep.check(b"\x00\x00\x00\x01" in joined or b"\x00\x00\x01" in joined,
                  "视频流含 H.264 Annex-B 起始码",
                  "找到 00 00 00 01 或 00 00 01", warn_only=True)

    fg = [pl for st, pl, _t in cmsgs if st == MD_FOREGROUND]
    rep.check(len(fg) > 0, f"CMD(7240) 周期性上报 {MD_FOREGROUND} MD_FOREGROUND（保活）",
              f"共 {len(fg)} 条 —— 车机端要求 5 秒内收到任意消息")

    # ── 10b. 音频通路校验（MEDIA_INIT + MEDIA_DATA，Ch3/9240）──
    # 官方依据：CommonParams.java / CTranRecvPackageProcess.h（0x0003 块），
    # 字段见 CarlifeMusicInitProto.proto；HU 侧映射：
    #   channelConfig 1=mono / 2=stereo；sampleFormat 8=PCM8 / 16=PCM16。
    audio = next((c for c in extra if c.label == "AUDIO"), None)
    if audio is not None:
        with audio._lock:
            amsgs = list(audio.rx_msgs)
        init_idx_list = [i for i, (st, _, _t) in enumerate(amsgs) if st == MEDIA_INIT]
        data_frames = [(i, pl) for i, (st, pl, _t) in enumerate(amsgs) if st == MEDIA_DATA]
        stop_events = [(i, t) for i, (st, _, t) in enumerate(amsgs) if st == MEDIA_STOP]
        stop_count = len(stop_events)
        if init_idx_list:
            init_idx = init_idx_list[-1]
            d = pb_to_dict(amsgs[init_idx][1], MEDIA_INIT)
            rep.check(d.get("sampleRate", 0) > 0 and d.get("channelConfig", 0) in (1, 2)
                      and d.get("sampleFormat", 0) in (8, 16),
                      "MEDIA_INIT(CarlifeMusicInit) 字段合法（HU 映射："
                      "channelConfig 1=mono/2=stereo，sampleFormat 8/16=位深）",
                      show("CarlifeMusicInit", d, ["sampleRate", "channelConfig", "sampleFormat"]))
            rep.check(init_idx < (data_frames[0][0] if data_frames else len(amsgs)),
                      "MEDIA_INIT 先于所有 MEDIA_DATA 到达（车机靠它建 AudioTrack）",
                      f"INIT 在第 {init_idx} 条，DATA 共 {len(data_frames)} 帧")
        else:
            rep.add("WARN", "未收到 MEDIA_INIT —— 手机当时无音频播放则属正常"
                            "（内录采集只在有声音时产 buffer）；确有播放无声才算问题")
        rep.check(len(data_frames) > 0, f"AUDIO(9240) 收到 {MEDIA_DATA} PCM 数据帧",
                  f"共 {len(data_frames)} 帧 / {sum(len(pl) for _, pl in data_frames)}B")
        if data_frames:
            sizes = sorted(len(pl) for _, pl in data_frames)
            rep.check(0 < sizes[0] and sizes[-1] <= 100 * 1024,
                      "PCM 帧大小合理（>0 且 ≤ HU 侧 MEDIA_DATA_SIZE=100KB）",
                      f"最小 {sizes[0]}B / 中位 {sizes[len(sizes)//2]}B / 最大 {sizes[-1]}B")
            mid = sizes[len(sizes) // 2]
            rep.check(192 <= mid <= 38400,
                      "PCM 帧大小与 48kHz/2ch/16bit 的 1~200ms 分片量级吻合",
                      f"中位 {mid}B（10ms 满帧应为 1920B）", warn_only=True)
        # ★ MEDIA_STOP 归属判定：只有「mock 还在发视频心跳时」到达的 STOP 才算
        #   手机侧主动停流（异常）；心跳停止后的 STOP 是正常的拆链收尾
        #   （实测：mock 到期不发心跳 → 手机很快 STOP 音频并拆链，2026-10-16 真机）。
        stop_during_stream = [t for _i, t in stop_events if t <= last_hb_at + 0.5]
        if stop_during_stream:
            rep.add("WARN", f"推流期间收到 MEDIA_STOP ×{len(stop_during_stream)}"
                            "（手机侧主动停过音频流；若未操作过即为异常）")
        elif stop_count > 0:
            print(f"[INFO] MEDIA_STOP ×{stop_count} 到达于心跳停止后，属正常拆链收尾，不计警告")

    # ── 11. 附加通道存活情况 ──
    # ★ 用「心跳循环退出瞬间」的快照判定，而不是循环结束 0.3s 后的 alive：
    #   mock 到期停止心跳后，手机/沙箱代理会在极短时间内拆链，晚取会把正常的
    #   拆链时序误判成"中途掉线"。stopped_by_disconnect=True 才是真掉线。
    if stopped_by_disconnect:
        rep.check(False, "推流期间 CMD(7240) 连接被异常断开",
                  "心跳循环因 cmd.alive=False 提前退出 —— 连接在跑完前就断了")
    if touch is not None:
        rep.check(alive_at_end.get("TOUCH", touch.alive),
                  "TOUCH(9340) 下发触控后连接仍存活（手机端未因丢包断开）",
                  f"TOUCH 收 {touch.rx_bytes}B / {len(touch.rx_msgs)} 条"
                  f"｜快照 alive={alive_at_end.get('TOUCH')}")
    for c in extra:
        if c.label != "TOUCH":
            rep.check(alive_at_end.get(c.label, c.alive),
                      f"{c.label}({c.port}) 全程保持连接",
                      f"收 {c.rx_bytes}B / {len(c.rx_msgs)} 条"
                      f"｜快照 alive={alive_at_end.get(c.label)}")

    for c in extra:
        c.close()
    cmd.close()
    video.close()

    print(f"\n[DONE] 发心跳 {sent} 次；CMD 收 {len(cmsgs)} 条 / VIDEO 收 {len(vmsgs)} 条"
          + (f" / 附加通道 {len(extra)} 条" if extra else ""))
    fails = rep.dump()
    if args.strict and fails:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
