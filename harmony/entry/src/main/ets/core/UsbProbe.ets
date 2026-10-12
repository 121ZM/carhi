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
 *   鸿蒙对此的能力（@ohos.usbManager，API 14+，本工程 API 26）：
 *     getAccessoryList() / hasAccessoryRight() / requestAccessoryRight()
 *     openAccessory() -> USBAccessoryHandle.accessoryFd / closeAccessory()
 *   另有一套 Host 侧接口（getDevices / connectDevice / bulkTransfer），用于手机当 Host 的场景。
 *
 * 本模块职责：**只诊断、不改链路**。
 *   插上 USB 后，它能告诉你「车机走了哪条路、手机有没有拿到 IP、配件有没有被识别」，
 *   从而决定后续是「零改造」还是「新增 USB 传输层」。
 *   诊断结果不影响既有 WiFi 功能。
 *
 * 为什么必须先诊断：路 A 与路 B 的实现量差一个数量级，猜错会白写一大块代码。
 *   历史上本项目就吃过「拿猜测当结论」的亏（曾误判 98316 为 PAUSE 导致周期性掉线）。
 */

import { usbManager, BusinessError } from '@kit.BasicServicesKit';
import { connection } from '@kit.NetworkKit';

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
    console.info(`${TAG} probe kind=${kind} nets=${netIfaces.join('|')} acc=${accessories.length}`);
    return result;
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
}
