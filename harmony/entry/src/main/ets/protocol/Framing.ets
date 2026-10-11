/**
 * CarLife 报文帧封包与拆包
 *
 * 对齐参考实现：refs/carlife_pc_tool/protocol/framing.py
 * 上游依据：
 *   - 报文头结构：sources/d/b/a/a/o/h/a.java:134-147, 204-228, 290-298
 *   - 大端序整数处理：sources/c/b/k/m.java:663-666, 1188-1205
 *
 * 报文格式（全大端序 Big-Endian）：
 *   Channel 1 / 6 (8 字节头)：[uint16 len][uint16 reserved][uint32 service_type] + payload
 *   其他通道     (12 字节头)：[uint32 len][uint32 seq_or_ts][uint32 service_type] + payload
 */

import { CHANNEL_CMD, CHANNEL_TOUCH } from './Constants';

/**
 * 报文头长度。Ch1(控制) 与 Ch6(触控) 为 8 字节，其余通道 12 字节。
 * 依据 sources/d/b/a/a/o/h/a.java:134
 */
export function getHeaderSize(channel: number): number {
  return (channel === CHANNEL_CMD || channel === CHANNEL_TOUCH) ? 8 : 12;
}

/**
 * 判断通道是否使用 8 字节短头
 */
function isShortHeaderChannel(channel: number): boolean {
  return channel === CHANNEL_CMD || channel === CHANNEL_TOUCH;
}

/**
 * 打包 CarLife 报文帧。
 * 依据 sources/d/b/a/a/o/h/a.java:212-218 及 y() 方法
 *
 * @param channel 通道号
 * @param serviceType 消息 ID
 * @param payload 负载字节（Protobuf 序列化结果），可为空
 * @param seqOrTs 12 字节头通道使用的序列号/时间戳，短头通道忽略
 */
export function packMessage(channel: number, serviceType: number, payload: Uint8Array, seqOrTs: number = 0): Uint8Array {
  const payloadLen: number = payload.length;
  const headerSize: number = getHeaderSize(channel);
  const out = new Uint8Array(headerSize + payloadLen);
  const view = new DataView(out.buffer);

  if (isShortHeaderChannel(channel)) {
    // [uint16 len][uint16 reserved][uint32 service_type]
    view.setUint16(0, payloadLen, false);
    view.setUint16(2, 0, false);
    view.setUint32(4, serviceType, false);
  } else {
    // [uint32 len][uint32 seq_or_ts][uint32 service_type]
    view.setUint32(0, payloadLen, false);
    view.setUint32(4, seqOrTs, false);
    view.setUint32(8, serviceType, false);
  }

  if (payloadLen > 0) {
    out.set(payload, headerSize);
  }
  return out;
}

/** 解析后的报文头 */
export interface MessageHeader {
  payloadLen: number;
  extraField: number;   // 短头通道为保留字段(0)，长头通道为 seq/时间戳
  serviceType: number;
}

/**
 * 解析包头字节。
 * 依据 sources/d/b/a/a/o/h/a.java:140-147 及 m() 方法
 *
 * @param channel 通道号
 * @param headerBytes 至少 headerSize 长度的字节
 */
export function unpackHeader(channel: number, headerBytes: Uint8Array): MessageHeader {
  const headerSize: number = getHeaderSize(channel);
  if (headerBytes.length < headerSize) {
    throw new Error(`Header too short for channel ${channel}: ${headerBytes.length} < ${headerSize}`);
  }
  const view = new DataView(headerBytes.buffer, headerBytes.byteOffset, headerBytes.byteLength);
  if (isShortHeaderChannel(channel)) {
    const payloadLen: number = view.getUint16(0, false);
    const reserved: number = view.getUint16(2, false);
    const serviceType: number = view.getUint32(4, false);
    return { payloadLen, extraField: reserved, serviceType };
  } else {
    const payloadLen: number = view.getUint32(0, false);
    const seqTs: number = view.getUint32(4, false);
    const serviceType: number = view.getUint32(8, false);
    return { payloadLen, extraField: seqTs, serviceType };
  }
}

/** 一条完整报文 */
export interface Message {
  serviceType: number;
  payload: Uint8Array;
}

/**
 * TCP 字节流读取器：保证从 Socket 中完整读取指定字节数，
 * 处理 TCP 分包/粘包。对应 framing.py 的 recv_exact。
 *
 * 使用方式：持续调用 feed() 投喂 Socket 收到的数据，
 * 每次 feed 后调用 tryRead() 尝试取出一条完整报文。
 */
export class MessageStreamReader {
  private channel: number;
  private headerSize: number;
  private buffer: Uint8Array = new Uint8Array(0);

  constructor(channel: number) {
    this.channel = channel;
    this.headerSize = getHeaderSize(channel);
  }

  /** 投喂新收到的字节 */
  feed(data: Uint8Array): void {
    if (data.length === 0) {
      return;
    }
    const merged = new Uint8Array(this.buffer.length + data.length);
    merged.set(this.buffer, 0);
    merged.set(data, this.buffer.length);
    this.buffer = merged;
  }

  /** 缓冲区中当前累积的字节数 */
  get pending(): number {
    return this.buffer.length;
  }

  /**
   * 尝试取出一条完整报文。
   * 数据不足时返回 null（等待更多数据）。
   */
  tryRead(): Message | null {
    if (this.buffer.length < this.headerSize) {
      return null;
    }
    const headerBytes = this.buffer.subarray(0, this.headerSize);
    const header: MessageHeader = unpackHeader(this.channel, headerBytes);
    const totalLen: number = this.headerSize + header.payloadLen;
    if (this.buffer.length < totalLen) {
      return null;   // 负载未收全，继续等待
    }
    const payload = this.buffer.slice(this.headerSize, totalLen);
    this.buffer = this.buffer.slice(totalLen);
    return { serviceType: header.serviceType, payload };
  }

  /** 清空缓冲区 */
  reset(): void {
    this.buffer = new Uint8Array(0);
  }
}
