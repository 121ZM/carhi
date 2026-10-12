#!/usr/bin/env python3
"""
模拟车机（HU）客户端 —— 完整握手版。

用途：在没有真实车机的情况下驱动手机端 CarLife 实现走完整流程，
     用于验证握手、心跳、掉线判定、帧率变更等逻辑。

流程（对照 refs/OFFICIAL_PROTOCOL.md 的握手主链路）：
  1. 连 CONTROL(7240)
  2. 发 98305 HU_PROTOCOL_VERSION(major=4, minor=1)
  3. 收 65538 / 65540
  4. 发 98343 HU_STATISTICAL_INFO
  5. 发 98307 HU_INFO（设备信息）
  6. 发 98376 HU_AUTHEN_REQUEST
  7. 发 98311 HU_VIDEO_ENCODER_INIT（分辨率/帧率）
  8. 发 98313 VIDEO_ENCODER_START
  9. 连 VIDEO(8240)，周期性发 131074 心跳

报文格式（全大端序）：
  Ch1/Ch6 (8 字节头)：[uint16 len][uint16 reserved][uint32 service_type] + payload
  其它通道 (12 字节头)：[uint32 len][uint32 seq_or_ts][uint32 service_type] + payload

用法：
  python mock_hu.py --video-port 8240 --cmd-port 7240 --duration 60
"""

import argparse
import socket
import struct
import sys
import threading
import time

# ---- 车机 -> 手机 ----
HU_PROTOCOL_VERSION = 98305
HU_STATISTICAL_INFO = 98343
HU_INFO = 98307
HU_AUTHEN_REQUEST = 98376
HU_VIDEO_ENCODER_INIT = 98311
VIDEO_ENCODER_START = 98313
VIDEO_HEARTBEAT = 131074
HU_FEATURE_CONFIG_RESPONSE = 98386

# ---- 手机 -> 车机（用于日志识别）----
NAMES = {
    65538: "MD_PROTOCOL_VERSION_MATCH_STATUS",
    65540: "MD_INFO",
    65611: "MD_AUTHEN_RESULT",
    65617: "MD_FEATURE_CONFIG_LIST",
    65544: "MD_VIDEO_ENCODER_INIT",
    65549: "MD_VIDEO_FRAME_RATE",
    65551: "MD_VIDEO_ENCODER_INIT_DONE",
}


def pack(channel: int, service_type: int, payload: bytes = b"", seq: int = 0) -> bytes:
    """按通道类型封包"""
    if channel in (1, 6):
        return struct.pack(">HHI", len(payload), 0, service_type) + payload
    return struct.pack(">III", len(payload), seq, service_type) + payload


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
    """protobuf: 字段号 + varint"""
    return varint((field << 3) | 0) + varint(value)


def pb_bytes(field: int, data: bytes) -> bytes:
    return varint((field << 3) | 2) + varint(len(data)) + data


class Channel:
    """单个通道的客户端封装，带后台读取线程"""

    def __init__(self, host: str, port: int, channel: int, label: str):
        self.host, self.port, self.channel, self.label = host, port, channel, label
        self.sock: socket.socket | None = None
        self.alive = False
        self.rx_bytes = 0
        self.rx_msgs: list[tuple[int, int]] = []   # (service_type, len)
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
        """后台读取并解析手机端回传的报文"""
        buf = bytearray()
        hdr = 8 if self.channel in (1, 6) else 12
        while self.alive and self.sock:
            try:
                chunk = self.sock.recv(65536)
                if not chunk:
                    print(f"[{self.label}] 对端关闭连接")
                    self.alive = False
                    break
                buf.extend(chunk)
                self.rx_bytes += len(chunk)
                # 尽量多解析几条
                while len(buf) >= hdr:
                    if hdr == 8:
                        plen, _, stype = struct.unpack(">HHI", bytes(buf[:8]))
                    else:
                        plen, _, stype = struct.unpack(">III", bytes(buf[:12]))
                    if len(buf) < hdr + plen:
                        break
                    del buf[: hdr + plen]
                    with self._lock:
                        self.rx_msgs.append((stype, plen))
                    name = NAMES.get(stype, f"0x{stype:08X}")
                    print(f"[{self.label}] <- 收到 {name} (ID={stype}, len={plen})")
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
            name = NAMES.get(service_type) or {
                HU_PROTOCOL_VERSION: "HU_PROTOCOL_VERSION",
                HU_STATISTICAL_INFO: "HU_STATISTICAL_INFO",
                HU_INFO: "HU_INFO",
                HU_AUTHEN_REQUEST: "HU_AUTHEN_REQUEST",
                HU_VIDEO_ENCODER_INIT: "HU_VIDEO_ENCODER_INIT",
                VIDEO_ENCODER_START: "VIDEO_ENCODER_START",
                HU_FEATURE_CONFIG_RESPONSE: "HU_FEATURE_CONFIG_RESPONSE",
                VIDEO_HEARTBEAT: "VIDEO_HEARTBEAT",
            }.get(service_type, f"0x{service_type:08X}")
            print(f"[{self.label}] -> 发送 {name} (ID={service_type}, len={len(payload)})")
        except OSError as e:
            print(f"[{self.label}] 发送失败 -> {e}")
            self.alive = False

    def close(self) -> None:
        self.alive = False
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--cmd-port", type=int, default=7240)
    ap.add_argument("--video-port", type=int, default=8240)
    ap.add_argument("--width", type=int, default=1280)
    ap.add_argument("--height", type=int, default=720)
    ap.add_argument("--fps", type=int, default=30)
    ap.add_argument("--hb-hz", type=float, default=5.0, help="心跳频率 次/秒")
    ap.add_argument("--duration", type=int, default=90)
    ap.add_argument("--skip-handshake", action="store_true")
    args = ap.parse_args()

    # ---------- 1. 控制通道：走握手 ----------
    cmd = Channel(args.host, args.cmd_port, 1, "CMD")
    if not cmd.connect():
        return 1

    if not args.skip_handshake:
        time.sleep(0.3)
        # 98305 版本协商：major=4, minor=1
        cmd.send(HU_PROTOCOL_VERSION, pb_int(1, 4) + pb_int(2, 1))
        time.sleep(0.5)

        # 98343 统计信息（内容手机端不强依赖，给个最小合法体）
        cmd.send(HU_STATISTICAL_INFO, pb_int(1, 1) + pb_int(2, 0))
        time.sleep(0.4)

        # 98307 设备信息
        info = (pb_bytes(1, b"samsung") + pb_bytes(2, b"SM-N9860")
                + pb_bytes(3, b"TQ2A.230505.002 release-keys"))
        cmd.send(HU_INFO, info)
        time.sleep(0.2)

        # 98376 鉴权请求
        cmd.send(HU_AUTHEN_REQUEST, b"")
        time.sleep(0.3)

        # 98311 编码参数
        enc = (pb_int(1, args.width) + pb_int(2, args.height) + pb_int(3, args.fps))
        cmd.send(HU_VIDEO_ENCODER_INIT, enc)
        time.sleep(0.3)

        # 98386 特征配置响应（内容手机端只记录）
        cmd.send(HU_FEATURE_CONFIG_RESPONSE, b"\x08\x01")
        time.sleep(0.2)

        # 98313 确认开始推流
        cmd.send(VIDEO_ENCODER_START, b"")

    # ---------- 2. 视频通道：发心跳 ----------
    video = Channel(args.host, args.video_port, 2, "VIDEO")
    if not video.connect():
        print("[VIDEO] 视频通道连不上，仅使用控制通道")

    interval = 1.0 / args.hb_hz
    deadline = time.time() + args.duration
    sent = 0
    last = time.time()

    print(f"[INFO] 开始心跳 131074 @ {args.hb_hz}/s，持续 {args.duration}s")

    try:
        while time.time() < deadline and cmd.alive:
            video.send(VIDEO_HEARTBEAT)
            sent += 1
            now = time.time()
            if now - last >= 10.0:
                with video._lock:
                    n_v = len(video.rx_msgs)
                print(f"[STAT] 心跳 {sent} 次 | video 收 {video.rx_bytes}B/{n_v}条"
                      f" | cmd 收 {cmd.rx_bytes}B | alive cmd={cmd.alive} video={video.alive}")
                last = now
            time.sleep(interval)
    except KeyboardInterrupt:
        print("\n[INFO] 中断")
    finally:
        video.close()
        cmd.close()

    with cmd._lock:
        got = cmd.rx_msgs
    print(f"[DONE] 发心跳 {sent} 次；控制通道收到 {len(got)} 条回包:")
    for stype, plen in got:
        print(f"        {NAMES.get(stype, hex(stype))} (ID={stype}, len={plen})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
