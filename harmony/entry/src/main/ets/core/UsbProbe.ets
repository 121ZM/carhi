/**
 * USB 连接诊断（UsbProbe）
 *
 * 背景（SDK 实证，非推测）：
 *   本项目的 CarLife 手机端走的是「手机 TCP 服务端 / 车机 TCP 客户端」模型。
 *   WiFi 模式下链路清晰；USB 直连模式下，物理承载换成 USB，但存在**两条完全不同的路**：
 *
 *   路 A —— CDC-ECM / RNDIS（USB 网络模式）
 *     车机把手机当成一块 USB 网卡，双方各得一个 IP，然后在 IP 网络上跑 TCP。
 *     → 手机端**无需改代码**：ChannelServer 已监听 '0.0.0.0'，USB 网卡上的连接自动可收。
 *
 *   路 B —— AOA（Android Open Accessory，非网络模式）
 *     车机通过 AOA 控制请求把手机切到 accessory 模式，直接把字节流走 USB 批量端点，
 *     不建立 IP 网络。此时手机端需要：
 *       ① getAccessoryList() 看到配件
 *       ② requestAccessoryRight() + openAccessory() 拿到 accessoryFd
 *       ③ 用 Core File Kit 的 read/write 在 fd 上收发，并自行解析字节流
 *     → 手机端需要**新增 USB 传输通道**（工作量较大）。
 *
 *   鸿蒙对此的能力（@ohos.usbManager，API 14+，本工程 API 26，已对照 d.ts 核实）：
 *     getAccessoryList() / hasAccessoryRight() / requestAccessoryRight() / cancelAccessoryRight()
 *     openAccessory() -> USBAccessoryHandle.accessoryFd / closeAccessory()
 *     以上接口 **均无 @permission 标注**（不需要额外申请权限），
 *     但 openAccessory 会抛 14400001（需先 requestAccessoryRight 拿授权）。
 *   另有一套 Host 侧接口（getDevices / connectDevice / bulkTransfer），用于手机当 Host 的场景。
 *
 * 本模块职责：
 *   ① `probe()` —— **只诊断、不改链路**。插上 USB 后告诉你「车机走了哪条路、
 *      手机有没有拿到 IP、配件有没有被识别」，从而决定后续是「零改造」还是「新增 USB 传输层」。
 *   ② `tryAoa()` —— **真实试连**：真的 openAccessory() 拿 fd，并试读一段原始字节 dump 出来。
 *      这是唯一能同时回答两件事的手段：
 *        - 配件是真的存在，还是 getAccessoryList() 的假阳性（→ 决定要不要写传输层）
 *        - AOA 单字节流上到底长什么样（TCP 模式靠 7 个端口区分通道，帧头里**没有通道号**；
 *          USB 只有一条流，通道复用格式必须实测，不能猜）
 *
 * 为什么必须先诊断：路 A 与路 B 的实现量差一个数量级，猜错会白写一大块代码。
 *   历史上本项目就吃过「拿猜测当结论」的亏（曾误判 98316 为 PAUSE 导致周期性掉线）。
 */

import { usbManager, BusinessError } from '@kit.BasicServicesKit';
import { connection } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';

const TAG = 'CarLifeUsbProbe';

/** USB 链路形态判定结果 */
export enum UsbLinkKind {
  /** 没插 USB，或插了但车机尚未发起任何 USB 会话 */
  NONE = 0,
  /** 路 A：拿到了新的网络接口（USB 网卡），走 IP —— 手机端零改造 */
  IP_NETWORK = 1,
  /** 路 B：识别到 USB 配件（AOA），需要走 fd 字节流 */
  ACCESSORY = 2,
  /** 两者同时出现（少见，但记录下来） */
  BOTH = 3
}

/** 一次诊断的快照 */
export interface UsbProbeResult {
  kind: UsbLinkKind;
  /** 人类可读的结论 */
  summary: string;
  /** 当前所有网络接口（含 IP），重点看有没有 USB/RNDIS/ECM 之类的新网卡 */
  netIfaces: string[];
  /** Host 侧看到的 USB 设备（若手机作为 Host） */
  hostDevices: string[];
  /** 识别到的 USB 配件（AOA） */
  accessories: string[];
  /** 诊断过程中的错误（非致命） */
  errors: string[];
}

/** AOA 真实试连结果 */
export interface AoaProbeResult {
  /** 配件列表非空 */
  available: boolean;
  /** 已获得配件访问权限（hasAccessoryRight 或 requestAccessoryRight 成功） */
  granted: boolean;
  /** 成功 openAccessory() */
  opened: boolean;
  /** accessoryFd（有效为正整数） */
  fd: number;
  /** 试读到的字节数；0 表示超时无数据 */
  bytesRead: number;
  /** 读到的前若干字节（hex + ASCII） */
  hexDump: string;
  /** 失败/异常原因（空串表示无错） */
  error: string;
}

export class UsbProbe {
  private static last: UsbProbeResult | null = null;

  /** 最近一次诊断结果，未跑过时为 null */
  static get latest(): UsbProbeResult | null {
    return UsbProbe.last;
  }

  /**
   * 执行一次 USB 诊断。**只读**，不改变任何连接状态。
   *
   * 判定逻辑：
   *   - 有 accessory     → ACCESSORY（或 BOTH）
   *   - 有非 WiFi 的新网卡 → IP_NETWORK
   *   - 都没有           → NONE
   */
  static async probe(): Promise<UsbProbeResult> {
    const errors: string[] = [];
    const netIfaces: string[] = [];
    const hostDevices: string[] = [];
    const accessories: string[] = [];

    // ---------- 1. USB Host 侧设备列表 ----------
    // 若车机把自己枚举成设备（少见），这里能看到。失败多为开发者模式未开。
    try {
      const devs: Array<usbManager.USBDevice> = usbManager.getDevices();
      if (devs !== undefined && devs !== null) {
        for (let i = 0; i < devs.length; i++) {
          const d = devs[i];
          hostDevices.push(`vid=0x${d.vendorId.toString(16)} pid=0x${d.productId.toString(16)}`
            + ` class=${d.clazz} "${d.productName}"`);
        }
      }
    } catch (e) {
      const err = e as BusinessError;
      errors.push(`getDevices: ${err.message}`);
    }

    // ---------- 2. USB 配件（AOA） ----------
    // ★ 这一项是判定「路 B」的关键：车机发起 AOA 后，手机侧会出现在这里。
    try {
      const accs: Array<Readonly<usbManager.USBAccessory>> = usbManager.getAccessoryList();
      if (accs !== undefined && accs !== null) {
        for (let i = 0; i < accs.length; i++) {
          const a = accs[i];
          const granted: boolean = usbManager.hasAccessoryRight(a);
          accessories.push(`"${a.manufacturer}/${a.product}" ver=${a.version}`
            + ` sn=${a.serialNumber} 已授权=${granted}`);
        }
      }
    } catch (e) {
      const err = e as BusinessError;
      // 未插配件时该接口报错属正常，只记录不当作故障
      errors.push(`getAccessoryList: ${err.message}`);
    }

    // ---------- 3. 网络接口（判定「路 A」的关键） ----------
    // 若 USB 走 CDC-ECM/RNDIS，这里会多出一块网卡（常见名 usb0/rndis0/eth1，或带 v6/v4 地址）。
    try {
      const nets: Array<connection.NetHandle> = await connection.getAllNets();
      for (let i = 0; i < nets.length; i++) {
        // getConnectionProperties 是异步接口（有 Promise 重载），必须 await
        const props: connection.ConnectionProperties =
          await connection.getConnectionProperties(nets[i]);
        const name: string = props.interfaceName;
        const linkAddrs: Array<connection.LinkAddress> = props.linkAddresses;
        let addrText = '';
        for (let j = 0; j < linkAddrs.length; j++) {
          const la = linkAddrs[j];
          addrText += ` ${la.address.address}/${la.prefixLength}`;
        }
        netIfaces.push(`${name} [${addrText.trim()}]`);
      }
    } catch (e) {
      const err = e as BusinessError;
      errors.push(`getAllNets: ${err.message}`);
    }

    // ---------- 4. 综合判定 ----------
    let kind: UsbLinkKind = UsbLinkKind.NONE;
    const hasAccessory: boolean = accessories.length > 0;
    // WiFi 网卡名（本机实测为 wlan0），排除掉后若仍有其它网卡，多半就是 USB 虚拟网卡
    const usbLike: string[] = netIfaces.filter((s: string) =>
      !s.startsWith('wlan') && !s.startsWith('lo') && !s.startsWith('rmnet'));
    const hasUsbNet: boolean = usbLike.length > 0;

    if (hasAccessory && hasUsbNet) {
      kind = UsbLinkKind.BOTH;
    } else if (hasAccessory) {
      kind = UsbLinkKind.ACCESSORY;
    } else if (hasUsbNet) {
      kind = UsbLinkKind.IP_NETWORK;
    }

    let summary: string;
    switch (kind) {
      case UsbLinkKind.IP_NETWORK:
        summary = 'USB 网络模式(CDC-ECM/RNDIS)：手机已获得 USB 网卡，'
          + '现有 0.0.0.0 监听可直接接收车机连接 —— 理论上零改造';
        break;
      case UsbLinkKind.ACCESSORY:
        summary = 'USB 配件模式(AOA)：检测到配件但无独立网卡，'
          + '需新增 fd 字节流传输层（工作量较大）';
        break;
      case UsbLinkKind.BOTH:
        summary = '两种特征同时出现，需进一步确认实际数据走哪条路';
        break;
      default:
        summary = '未检测到 USB 会话：请确认已用数据线连接车机、'
          + '并在车机上启动了 CarLife';
        break;
    }

    const result: UsbProbeResult = { kind, summary, netIfaces, hostDevices, accessories, errors };
    UsbProbe.last = result;
    console.info(`${TAG} probe kind=${kind} nets=${netIfaces.join('|')}`
      + ` host=${hostDevices.length} acc=${accessories.length}`
      + ` accDetail=${accessories.join(';')} errors=${errors.join('|')}`);
    return result;
  }

  /**
   * AOA **真实试连**：openAccessory() 拿 fd，并试读一段原始字节。
   *
   * 注意：这是**会改变状态**的操作（打开配件 / 可能弹授权框），
   * 因此与只读的 probe() 分开。打开后无论成败都会立刻 closeAccessory()。
   *
   * 关键设计：试读用异步 `fs.read()`（返回 Promise，不阻塞 JS 线程），
   * 再与一个超时 Promise 赛跑。若车机没在推数据，最多等 AOA_READ_WAIT_MS 就收手，
   * 不会把界面卡死。
   */
  static async tryAoa(): Promise<AoaProbeResult> {
    const res: AoaProbeResult = {
      available: false, granted: false, opened: false,
      fd: -1, bytesRead: 0, hexDump: '', error: ''
    };
    let handle: usbManager.USBAccessoryHandle | null = null;
    try {
      // ---- 1. 列配件 ----
      const accs: Array<Readonly<usbManager.USBAccessory>> = usbManager.getAccessoryList();
      if (accs === undefined || accs === null || accs.length === 0) {
        res.error = '配件列表为空（车机未进入 AOA，或未插 USB）';
        return res;
      }
      res.available = true;
      const acc: Readonly<usbManager.USBAccessory> = accs[0];
      console.info(`${TAG} aoa accessory manufacturer="${acc.manufacturer}"`
        + ` product="${acc.product}" desc="${acc.description}"`
        + ` ver="${acc.version}" sn="${acc.serialNumber}"`);

      // ---- 2. 取访问授权 ----
      let granted: boolean = usbManager.hasAccessoryRight(acc);
      if (!granted) {
        // 可能弹出系统授权框（com.usb.right），需用户点「允许」
        granted = await usbManager.requestAccessoryRight(acc);
      }
      res.granted = granted;
      if (!granted) {
        res.error = '未获得配件访问权限（授权框被拒绝或超时）';
        return res;
      }

      // ---- 3. 打开配件拿 fd ----
      handle = usbManager.openAccessory(acc);
      res.opened = true;
      res.fd = handle.accessoryFd;
      console.info(`${TAG} aoa opened accessoryFd=${res.fd}`);

      // ---- 4. 试读原始字节 ----
      // fs.read 是异步接口（libuv 线程池执行），不会卡住 JS 线程；
      // 挂一个兜底 catch，避免超时后它才失败而变成"未处理的 Promise 拒绝"。
      const buf = new ArrayBuffer(UsbProbe.AOA_READ_MAX);
      const readP: Promise<number> = fs.read(res.fd, buf);
      readP.then(() => {
      }).catch(() => {
      });
      const racers: Array<Promise<number>> = [readP, UsbProbe.delay(UsbProbe.AOA_READ_WAIT_MS)];
      const n: number = await Promise.race(racers);
      if (n > 0) {
        res.bytesRead = n;
        res.hexDump = UsbProbe.hexDump(new Uint8Array(buf, 0, n));
      }
      console.info(`${TAG} aoa read n=${n} hex=${res.hexDump}`);
    } catch (e) {
      const err = e as BusinessError;
      res.error = `code=${err.code} ${err.message}`;
      console.error(`${TAG} aoa failed: ${res.error}`);
    } finally {
      if (handle !== null) {
        try {
          usbManager.closeAccessory(handle);
          console.info(`${TAG} aoa closed accessoryFd=${res.fd}`);
        } catch (e2) {
          // 配件可能已被拔出，忽略
        }
      }
    }
    return res;
  }

  /** 把诊断结果拼成可读的多行文本（给日志/UI 用） */
  static format(r: UsbProbeResult): string[] {
    const lines: string[] = [];
    lines.push(`[USB诊断] 结论: ${r.summary}`);
    lines.push(`[USB诊断] 网络接口(${r.netIfaces.length}): ${r.netIfaces.length > 0 ? r.netIfaces.join(', ') : '无'}`);
    lines.push(`[USB诊断] USB设备(${r.hostDevices.length}): ${r.hostDevices.length > 0 ? r.hostDevices.join(', ') : '无'}`);
    lines.push(`[USB诊断] USB配件(${r.accessories.length}): ${r.accessories.length > 0 ? r.accessories.join(', ') : '无'}`);
    if (r.errors.length > 0) {
      lines.push(`[USB诊断] 查询异常(${r.errors.length}): ${r.errors.join(' | ')}`);
    }
    return lines;
  }

  /** 把 AOA 试连结果拼成可读文本 */
  static formatAoa(r: AoaProbeResult): string[] {
    const lines: string[] = [];
    lines.push(`[AOA试连] 配件存在=${r.available} 已授权=${r.granted} 已打开=${r.opened} fd=${r.fd}`);
    if (r.opened) {
      if (r.bytesRead > 0) {
        lines.push(`[AOA试连] 读到达 ${r.bytesRead} 字节: ${r.hexDump}`);
      } else {
        lines.push('[AOA试连] fd 已打开但试读超时无数据（车机可能还没开始发）');
      }
    }
    if (r.error !== '') {
      lines.push(`[AOA试连] 失败: ${r.error}`);
    }
    return lines;
  }

  /** 试读上限字节数（只取头部，够看封包格式即可） */
  private static readonly AOA_READ_MAX: number = 256;
  /** 试读等待上限（毫秒），到点就收手，避免界面卡住 */
  private static readonly AOA_READ_WAIT_MS: number = 1500;

  /** 超时用的哨兵 Promise：到点返回 -1 */
  private static delay(ms: number): Promise<number> {
    return new Promise<number>((resolve: (v: number) => void) => {
      setTimeout(() => resolve(-1), ms);
    });
  }

  /** 把字节转成 "hex  |ascii|" 形式，便于人眼识别封包结构 */
  private static hexDump(bytes: Uint8Array): string {
    const limit: number = bytes.length < 96 ? bytes.length : 96;
    const hex: string[] = [];
    const ascii: string[] = [];
    for (let i = 0; i < limit; i++) {
      const b: number = bytes[i];
      hex.push(b.toString(16).padStart(2, '0'));
      ascii.push((b >= 0x20 && b < 0x7f) ? String.fromCharCode(b) : '.');
    }
    const suffix: string = bytes.length > limit ? ` ...(共 ${bytes.length} 字节)` : '';
    return `${hex.join(' ')}  |${ascii.join('')}|${suffix}`;
  }
}
