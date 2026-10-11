/**
 * 极简 Protobuf 编解码器（ArkTS 自研）
 *
 * 为什么自研：鸿蒙 ArkTS 无官方 Protobuf 运行时，
 * protobuf.js 依赖 Node/DOM API 无法直接使用。
 * CarLife 只用 int32 / bool / string / repeated message 四种类型，
 * 手写覆盖即可，且可控可验。
 *
 * 对齐参考实现：refs/carlife_pc_tool/protocol/proto_codec.py
 *
 * Protobuf wire format 基础：
 *   varint  : 7 位一组，最高位为 continuation flag
 *   tag     : (field_number << 3) | wire_type
 *   wire type: 0=varint, 1=64bit, 2=length-delimited, 5=32bit
 */

// ================= Wire Type =================
export const WIRE_VARINT: number = 0;
export const WIRE_64BIT: number = 1;
export const WIRE_LENGTH_DELIMITED: number = 2;
export const WIRE_32BIT: number = 5;

// ================= 编码器 =================

/** Protobuf 写入器：按字段顺序写出字节 */
export class ProtobufWriter {
  private chunks: Uint8Array[] = [];

  /** 写一个 varint（无符号，使用无符号右移保证高位正确） */
  writeVarint(value: number): void {
    const out: number[] = [];
    // JS number 只有 53 位精度，此处用位运算处理 32 位以内的值
    let v: number = value;
    while (v > 0x7F) {
      out.push((v & 0x7F) | 0x80);
      v = v >>> 7;
    }
    out.push(v & 0x7F);
    this.chunks.push(new Uint8Array(out));
  }

  /** 写 tag：字段号 + wire type */
  writeTag(fieldNumber: number, wireType: number): void {
    this.writeVarint((fieldNumber << 3) | wireType);
  }

  /** 写 int32 / bool 字段（wire type 0） */
  writeInt32(fieldNumber: number, value: number): void {
    this.writeTag(fieldNumber, WIRE_VARINT);
    this.writeVarint(value);
  }

  /** 写 bool 字段（wire type 0） */
  writeBool(fieldNumber: number, value: boolean): void {
    this.writeInt32(fieldNumber, value ? 1 : 0);
  }

  /** 写 string 字段（wire type 2，长度前缀 + UTF-8） */
  writeString(fieldNumber: number, value: string): void {
    const bytes: Uint8Array = utf8Encode(value);
    this.writeTag(fieldNumber, WIRE_LENGTH_DELIMITED);
    this.writeVarint(bytes.length);
    this.chunks.push(bytes);
  }

  /** 写嵌套 message 字段（wire type 2） */
  writeMessage(fieldNumber: number, bytes: Uint8Array): void {
    this.writeTag(fieldNumber, WIRE_LENGTH_DELIMITED);
    this.writeVarint(bytes.length);
    this.chunks.push(bytes);
  }

  /** 合并所有分片为最终字节 */
  toBytes(): Uint8Array {
    let total: number = 0;
    for (let i = 0; i < this.chunks.length; i++) {
      total += this.chunks[i].length;
    }
    const out = new Uint8Array(total);
    let offset: number = 0;
    for (let i = 0; i < this.chunks.length; i++) {
      out.set(this.chunks[i], offset);
      offset += this.chunks[i].length;
    }
    return out;
  }
}

// ================= 解码器 =================

/** 解析出的一条字段 */
export interface Field {
  fieldNumber: number;
  wireType: number;
  /** varint 类型时为数值；length-delimited 时为字节 */
  varintValue: number;
  bytesValue: Uint8Array | null;
}

/** Protobuf 读取器 */
export class ProtobufReader {
  private data: Uint8Array;
  private pos: number = 0;

  constructor(data: Uint8Array) {
    this.data = data;
  }

  get eof(): boolean {
    return this.pos >= this.data.length;
  }

  /** 读一个 varint */
  readVarint(): number {
    let result: number = 0;
    let shift: number = 0;
    while (this.pos < this.data.length) {
      const b: number = this.data[this.pos++];
      result += (b & 0x7F) * Math.pow(2, shift);
      if ((b & 0x80) === 0) {
        break;
      }
      shift += 7;
      if (shift > 63) {
        throw new Error('varint too long');
      }
    }
    return result;
  }

  /** 读一个字段（tag + value） */
  readField(): Field {
    const tag: number = this.readVarint();
    const fieldNumber: number = Math.floor(tag / 8);
    const wireType: number = tag % 8;

    if (wireType === WIRE_VARINT) {
      const v: number = this.readVarint();
      return { fieldNumber, wireType, varintValue: v, bytesValue: null };
    } else if (wireType === WIRE_LENGTH_DELIMITED) {
      const len: number = this.readVarint();
      const bytes: Uint8Array = this.data.slice(this.pos, this.pos + len);
      this.pos += len;
      return { fieldNumber, wireType, varintValue: 0, bytesValue: bytes };
    } else if (wireType === WIRE_64BIT) {
      // 跳过 8 字节，读取时按 varint 近似（本项目未用到）
      const bytes: Uint8Array = this.data.slice(this.pos, this.pos + 8);
      this.pos += 8;
      return { fieldNumber, wireType, varintValue: 0, bytesValue: bytes };
    } else if (wireType === WIRE_32BIT) {
      const bytes: Uint8Array = this.data.slice(this.pos, this.pos + 4);
      this.pos += 4;
      return { fieldNumber, wireType, varintValue: 0, bytesValue: bytes };
    }
    throw new Error(`unsupported wire type: ${wireType}`);
  }
}

// ================= UTF-8 工具 =================

/**
 * 字符串转 UTF-8 字节。
 * ArkTS 环境不一定有 TextEncoder，此处手写实现保证可移植。
 */
export function utf8Encode(str: string): Uint8Array {
  const out: number[] = [];
  for (let i = 0; i < str.length; i++) {
    let code: number = str.charCodeAt(i);
    // 处理 UTF-16 代理对（surrogate pair）
    if (code >= 0xD800 && code <= 0xDBFF && i + 1 < str.length) {
      const next: number = str.charCodeAt(i + 1);
      if (next >= 0xDC00 && next <= 0xDFFF) {
        code = 0x10000 + ((code - 0xD800) << 10) + (next - 0xDC00);
        i++;
      }
    }
    if (code < 0x80) {
      out.push(code);
    } else if (code < 0x800) {
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

/** UTF-8 字节转字符串 */
export function utf8Decode(bytes: Uint8Array): string {
  let result: string = '';
  let i: number = 0;
  while (i < bytes.length) {
    const b: number = bytes[i];
    if (b < 0x80) {
      result += String.fromCharCode(b);
      i += 1;
    } else if (b < 0xE0) {
      const code: number = ((b & 0x1F) << 6) | (bytes[i + 1] & 0x3F);
      result += String.fromCharCode(code);
      i += 2;
    } else if (b < 0xF0) {
      const code: number = ((b & 0x0F) << 12) | ((bytes[i + 1] & 0x3F) << 6) | (bytes[i + 2] & 0x3F);
      result += String.fromCharCode(code);
      i += 3;
    } else {
      const code: number = ((b & 0x07) << 18) | ((bytes[i + 1] & 0x3F) << 12)
        | ((bytes[i + 2] & 0x3F) << 6) | (bytes[i + 3] & 0x3F);
      const cp: number = code - 0x10000;
      result += String.fromCharCode(0xD800 + (cp >> 10), 0xDC00 + (cp & 0x3FF));
      i += 4;
    }
  }
  return result;
}
