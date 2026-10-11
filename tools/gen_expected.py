#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
对拍基准生成器（Python 侧）
用官方 protobuf 库生成 CarLife 消息的标准字节，
输出为 JSON，供 Node 侧自研实现比对。

用法：python tools/gen_expected.py > tools/expected.json
"""

import sys
import os
import json

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'refs', 'carlife_pc_tool'))

from protocol import proto_codec, framing, constants


def b2h(b):
    """bytes -> hex string"""
    return b.hex()


def b2list(b):
    """bytes -> list[int]"""
    return list(b)


def main():
    result = {}

    # ---------- 1. CarlifeProtocolVersion ----------
    # 注：proto2 的 optional 字段「显式赋零值」会被编码，「未赋值」则跳过。
    # 手机端实际发送时只设置有意义的字段，此处按此语义构造基准。
    v = proto_codec.CarlifeProtocolVersion(majorVersion=4)
    result['CarlifeProtocolVersion'] = b2list(v.SerializeToString())

    # ---------- 2. CarlifeProtocolVersionMatchStatus ----------
    vms = proto_codec.CarlifeProtocolVersionMatchStatus(matchStatus=1, carlifeProtocolVersion=4)
    result['CarlifeProtocolVersionMatchStatus'] = b2list(vms.SerializeToString())

    # ---------- 3. CarlifeDeviceInfo（手机端真实信息，用它测多字段+字符串）----------
    dev = proto_codec.CarlifeDeviceInfo(
        os="HarmonyOS", board="ALN-AL00", bootloader="unknown", brand="HUAWEI",
        cpuAbi="arm64-v8a", cpuAbi2="armeabi-v7a", device="ALN-AL00",
        display="1260x2720", fingerprint="HUAWEI/ALN-AL00/ALN-AL00:12/HUAWEIALN-AL00/1:user/release-keys",
        hardware="kirin9000s", host="huawei-build", cid="HUAWEIALN-AL00",
        manufacturer="HUAWEI", model="ALN-AL00", product="ALN-AL00", serial="unknown",
        codename="REL", incremental="1", release="12", sdk="12", sdkInt=12,
        carlifeversion="8.4.0", btaddress="AA:BB:CC:DD:EE:FF"
    )
    result['CarlifeDeviceInfo'] = b2list(dev.SerializeToString())

    # ---------- 4. CarlifeStatisticsInfo ----------
    # crashCycle 留空即不设置（proto2 语义下不编码）
    stat = proto_codec.CarlifeStatisticsInfo(
        cuid="12345678", versionName="8.4.0", versionCode=16, channel="20029999",
        connectCount=1, connectSuccessCount=1, connectTime=1234
    )
    result['CarlifeStatisticsInfo'] = b2list(stat.SerializeToString())

    # ---------- 5. CarlifeAuthenResult ----------
    # 只测有效值；False 场景由「不设置该字段」表达，与手机端实际行为一致
    au = proto_codec.CarlifeAuthenResult(authenResult=True)
    result['CarlifeAuthenResult_true'] = b2list(au.SerializeToString())
    au2 = proto_codec.CarlifeAuthenResult()
    result['CarlifeAuthenResult_unset'] = b2list(au2.SerializeToString())

    # ---------- 6. CarlifeFeatureConfigList（含 repeated 嵌套消息）----------
    # huBtAudioSupport 不设置（False 由缺省表达）
    fcl = proto_codec.CarlifeFeatureConfigList()
    fcl.cnt = 3
    fcl.huBtName = "CarLife_Phone"
    fcl.huBtMAC = "AA:BB:CC:DD:EE:FF"
    f1 = fcl.featureConfig.add(); f1.key = "USB_MTU"; f1.value = 16384
    f2 = fcl.featureConfig.add(); f2.key = "I_FRAME_INTERVAL"; f2.value = 300
    f3 = fcl.featureConfig.add(); f3.key = "CONNECT_TYPE"; f3.value = 2
    result['CarlifeFeatureConfigList'] = b2list(fcl.SerializeToString())

    # ---------- 7. CarlifeVideoEncoderInfo ----------
    enc = proto_codec.CarlifeVideoEncoderInfo(width=1280, height=720, frameRate=30)
    result['CarlifeVideoEncoderInfo'] = b2list(enc.SerializeToString())

    # ---------- 8. CarlifeTouchAction ----------
    # action 不设置（ACTION_DOWN=0 由缺省表达）
    ta = proto_codec.CarlifeTouchAction(x=640, y=360, pointerx=640, pointery=360)
    result['CarlifeTouchAction'] = b2list(ta.SerializeToString())

    # ---------- 9. CarlifeCarHardKeyCode ----------
    hk = proto_codec.CarlifeCarHardKeyCode(keycode=1)
    result['CarlifeCarHardKeyCode'] = b2list(hk.SerializeToString())

    # ---------- 10. CarlifeMusicInit ----------
    mi = proto_codec.CarlifeMusicInit(sampleRate=48000, channelConfig=2, sampleFormat=2)
    result['CarlifeMusicInit'] = b2list(mi.SerializeToString())

    # ---------- 报文封包（两个通道的头部差异）----------
    # Channel 1（8 字节头）
    pkt_cmd = framing.pack_message(constants.CHANNEL_CMD, constants.MSG_CMD_MD_INFO, dev.SerializeToString())
    result['FRAME_ch1_MD_INFO'] = b2list(pkt_cmd)

    # Channel 1 空负载（心跳）
    pkt_hb = framing.pack_message(constants.CHANNEL_CMD, constants.MSG_CMD_MD_HEARTBEAT, b'')
    result['FRAME_ch1_heartbeat_empty'] = b2list(pkt_hb)

    # Channel 2（12 字节头，带 seq）
    fake_h264 = bytes([0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0x00, 0x1E])
    pkt_video = framing.pack_message(constants.CHANNEL_VIDEO, constants.MSG_VIDEO_DATA, fake_h264, seq_or_ts=42)
    result['FRAME_ch2_video'] = b2list(pkt_video)

    # Channel 6（短头）
    pkt_touch = framing.pack_message(constants.CHANNEL_TOUCH, constants.MSG_TOUCH_ACTION, ta.SerializeToString())
    result['FRAME_ch6_touch'] = b2list(pkt_touch)

    # 边界：大 varint（16384 需要 3 字节 varint）
    big = proto_codec.CarlifeVideoEncoderInfo(width=1920, height=1080, frameRate=60)
    result['CarlifeVideoEncoderInfo_1080p60'] = b2list(big.SerializeToString())

    json.dump(result, sys.stdout, indent=2)


if __name__ == '__main__':
    main()
