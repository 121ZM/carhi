/**
 * CarLife 传输层：7 端口 TCP 服务端
 *
 * 对齐参考实现：refs/carlife_pc_tool/transport/connector.py（方向相反：车机侧连手机侧）
 *
 * 关键架构事实：**手机端是服务端，车机是客户端**。
 * 手机端在 7240/8240/9240/9241/9242/9340/9440 上监听，车机主动来连。
 * 这也是本方案不需要 USB 从设备模式的原因 —— 全程走 WiFi TCP。
 *
 * 上游依据：
 *   - 端口定义：sources/d/b/a/a/p/o/e/c.java:16
 *   - Socket 读写：sources/d/b/a/a/o/i/f/c.java:79-100
 *
 * API 说明（已对照 SDK 声明文件核实）：
 *   鸿蒙的 TCPSocketConnection **没有** read() 方法，数据通过
 *   on('message', ...) 事件推送；发送用 send({ data: ArrayBuffer })。
 */

import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ALL_CHANNELS, ChannelDef, CHANNEL_AUDIO, CHANNEL_CMD, CHANNEL_VIDEO } from '../protocol/Constants';
import { MessageStreamReader, Message } from '../protocol/Framing';

const TAG = 'CarLifeChannelServer';

/** 通道连接事件回调 */
export interface ChannelServerListener {
  /** 某通道有车机连入 */
  onChannelConnected?: (channel: number) => void;
  /** 某通道断开 */
  onChannelDisconnected?: (channel: number) => void;
  /** 控制通道收到报文 */
  onCommandMessage?: (msg: Message) => void;
  /**
   * 视频通道收到报文。
   *
   * 作用：车机经 VIDEO 通道(8240)下发 `131074` 心跳，官方每 200ms 轮询读取，
   * 收到即刷新保活时间戳。**本通道的入站数据必须处理，不能丢弃** ——
   * 丢了会让车机判定手机失联，表现为周期性断开重连。
   */
  onVideoMessage?: (msg: Message) => void;
  /**
   * 其余通道（AUDIO / TTS / VR / TOUCH / DATA）收到报文。
   *
   * ★ 这些通道**并非"只发不收"**，此前这里没有回调，数据读进来即被丢弃：
   *   - TOUCH(9340, Ch6)：车机在这里下发触控事件（`CarlifeTouchAction` 425985 等）
   *     —— 车机屏幕上点的每一下都走这条路，丢了就"点不动"。
   *   - DATA(9440, Ch7)：双向（车况 / 媒体信息）。
   *   - AUDIO/TTS/VR：主要出站，入站多为状态通知。
   */
  onOtherMessage?: (channel: number, msg: Message) => void;
  /** 出错 */
  onError?: (channel: number, err: string) => void;
}

/** 把 Uint8Array 转成精确长度的 ArrayBuffer（send 接口只接受 ArrayBuffer） */
function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const copy = new Uint8Array(bytes.length);
  copy.set(bytes);
  return copy.buffer;
}

/** 单个通道的服务端封装 */
class ChannelServer {
  channel: number;
  port: number;
  desc: string;
  private server: socket.TCPSocketServer | null = null;
  private conn: socket.TCPSocketConnection | null = null;
  private reader: MessageStreamReader;
  private listener: ChannelServerListener;
  private closed: boolean = false;

  constructor(def: ChannelDef, listener: ChannelServerListener) {
    this.channel = def.channel;
    this.port = def.port;
    this.desc = def.desc;
    this.reader = new MessageStreamReader(def.channel);
    this.listener = listener;
  }

  get isConnected(): boolean {
    return this.conn !== null;
  }

  /** 启动监听 */
  async listen(): Promise<void> {
    const srv: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();

    // 视频流对延迟极敏感：必须关掉 Nagle 算法，否则小包会被攒着一起发，
    // 表现为画面迟滞。参考实现 connector.py:121 同样做了这一步。
    const extra: socket.TCPExtraOptions = {
      TCPNoDelay: true,
      keepAlive: true
    };
    try {
      await srv.setExtraOptions(extra);
    } catch (e) {
      // 部分平台/版本可能不支持该选项，失败不阻断监听
      console.warn(`${TAG} setExtraOptions failed on :${this.port}`);
    }

    // 监听连接事件：车机连入
    srv.on('connect', (conn: socket.TCPSocketConnection) => {
      this.handleConnection(conn);
    });

    const address: socket.NetAddress = {
      address: '0.0.0.0',
      port: this.port,
      family: 1   // 1 = IPv4
    };
    await srv.listen(address);
    this.server = srv;
  }

  /** 处理车机连入 */
  private handleConnection(conn: socket.TCPSocketConnection): void {
    // 单通道只保留一个活跃连接（CarLife 语义：一条通道一个连接）
    if (this.conn !== null) {
      this.closeConnection();
    }
    this.conn = conn;
    this.reader.reset();

    conn.on('message', (info: socket.SocketMessageInfo) => {
      if (this.conn !== conn || info === undefined || info.message === undefined) {
        return;
      }
      try {
        this.reader.feed(new Uint8Array(info.message));
        while (true) {
          const msg: Message | null = this.reader.tryRead();
          if (msg === null) {
            break;
          }
          if (this.channel === CHANNEL_CMD && this.listener.onCommandMessage) {
            this.listener.onCommandMessage(msg);
          } else if (this.channel === CHANNEL_VIDEO && this.listener.onVideoMessage) {
            // 视频通道并非"只发不收"：车机在这里下发 131074 心跳。
            // 漏掉这一条会导致车机判定手机失联 → 周期性断开重连。
            this.listener.onVideoMessage(msg);
          } else if (this.listener.onOtherMessage) {
            // ★ 其余通道也不是"只发不收"：TOUCH(9340) 承载车机的触控事件，
            //   DATA(9440) 是双向的。此前这里没有分支 → 数据读进来即被丢弃。
            this.listener.onOtherMessage(this.channel, msg);
          }
        }
      } catch (e) {
        const err = e as BusinessError;
        if (this.listener.onError) {
          this.listener.onError(this.channel, `parse failed: ${err.message}`);
        }
      }
    });

    conn.on('close', () => {
      if (this.conn === conn) {
        this.closeConnection();
      }
    });

    conn.on('error', (err: BusinessError) => {
      if (this.listener.onError) {
        this.listener.onError(this.channel, `socket error: ${err.message}`);
      }
    });

    if (this.listener.onChannelConnected) {
      this.listener.onChannelConnected(this.channel);
    }
  }

  /** 向该通道发送报文 */
  async send(bytes: Uint8Array): Promise<void> {
    const conn = this.conn;
    if (conn === null) {
      throw new Error(`channel ${this.channel} not connected`);
    }
    const options: socket.TCPSendOptions = { data: toArrayBuffer(bytes) };
    await conn.send(options);
  }

  /** 关闭当前连接 */
  private closeConnection(): void {
    const old = this.conn;
    if (old === null) {
      return;
    }
    this.conn = null;
    old.close().catch(() => {
      // 连接可能已被对端关闭，忽略
    });
    if (this.listener.onChannelDisconnected) {
      this.listener.onChannelDisconnected(this.channel);
    }
  }

  /** 停止服务并释放端口 */
  close(): void {
    this.closed = true;
    this.closeConnection();
    const srv = this.server;
    if (srv !== null) {
      this.server = null;
      try {
        srv.off('connect');
      } catch (e) {
        // 忽略
      }
      srv.close().catch(() => {
        // 忽略
      });
    }
  }
}

/**
 * CarLife 七通道服务端管理器。
 * 启动后在全部端口监听，等待车机连接。
 */
export class CarLifeChannelServer {
  private channels: Map<number, ChannelServer> = new Map();
  private listener: ChannelServerListener;
  private started: boolean = false;

  constructor(listener: ChannelServerListener) {
    this.listener = listener;
  }

  /**
   * 上一次 `start()` 的逐端口结果（形如 `:7240 OK` / `:7240 FAIL(xxx)`）。
   *
   * 为什么要暴露出来：`CarLifeEngine.start()` 原来在 `server.start()` 之后
   * **无条件**打印「已在 7240/... 端口监听」—— 哪怕 7 个端口全部绑定失败也照打，
   * 界面上就会出现「已监听」而实际一个都没绑上的假象。
   * 现在由调用方按**真实结果**说话。
   */
  private lastResults: string[] = [];
  /** 上一次 start() 里成功绑定的端口数 */
  private lastOkCount: number = 0;

  /** 逐端口结果，未启动过为空数组 */
  get listenResults(): string[] {
    return this.lastResults;
  }

  /** 成功绑定的端口数 */
  get listeningCount(): number {
    return this.lastOkCount;
  }

  /** 启动全部 7 个端口监听 */
  async start(): Promise<void> {
    if (this.started) {
      return;
    }
    const results: string[] = [];
    let okCount: number = 0;
    for (let i = 0; i < ALL_CHANNELS.length; i++) {
      const def: ChannelDef = ALL_CHANNELS[i];
      const srv = new ChannelServer(def, this.listener);
      try {
        await srv.listen();
        this.channels.set(def.channel, srv);
        results.push(`:${def.port} OK`);
        okCount++;
      } catch (e) {
        const err = e as BusinessError;
        results.push(`:${def.port} FAIL(${err.message})`);
        if (this.listener.onError) {
          this.listener.onError(def.channel, `listen failed: ${err.message}`);
        }
      }
    }
    this.lastResults = results;
    this.lastOkCount = okCount;
    this.started = true;
    console.info(`${TAG} listen result: ${results.join(', ')}`);
  }

  /** 指定通道是否已连接 */
  isConnected(channel: number): boolean {
    const c = this.channels.get(channel);
    return c !== undefined && c.isConnected;
  }

  /** 向指定通道发送 */
  async send(channel: number, bytes: Uint8Array): Promise<void> {
    const c = this.channels.get(channel);
    if (c === undefined) {
      throw new Error(`channel ${channel} not started`);
    }
    await c.send(bytes);
  }

  /** 控制通道是否就绪（生命线） */
  get isCommandReady(): boolean {
    return this.isConnected(CHANNEL_CMD);
  }

  /** 视频通道是否就绪 */
  get isVideoReady(): boolean {
    return this.isConnected(CHANNEL_VIDEO);
  }

  /** 媒体音频通道（Ch3/9240）是否就绪 */
  get isAudioReady(): boolean {
    return this.isConnected(CHANNEL_AUDIO);
  }

  /** 停止全部通道 */
  stop(): void {
    this.channels.forEach((c: ChannelServer) => {
      c.close();
    });
    this.channels.clear();
    this.started = false;
  }
}
