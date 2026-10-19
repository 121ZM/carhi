/**
 * WiFi / Wi-Fi Direct（P2P）探测与连接（WifiProbe）
 *
 * 背景：
 *   CarHi 的目标对端之一是「耘电车联 QH3002」无线转换盒。实测结论（真机 nova 14 Ultra /
 *   HarmonyOS 7.0.0.109）：
 *     - 盒子以 **`Box_259E`** 出现在 P2P 发现结果里（**不在**普通 WLAN 列表，扫 WiFi 找不到）
 *     - `p2pConnect()` 的 `passphrase` **传空串即可**（盒子无密码，框架自动协商）
 *     - 全套 P2P 接口只需 `ohos.permission.GET_WIFI_INFO`（normal / system_grant），
 *       **不需要位置权限** → 锁屏也能跑
 *     - ★ 盒子的 P2P MAC **不固定**（已观测到 3 个不同值）→ **必须每次先扫再连，不能缓存**
 *
 * 本模块职责：探测（probeP2p）/ 连接（connectP2p）/ 断开（disconnectP2p）。
 *
 * ─────────────────────────────────────────────────────────────────────────
 * 2026-10-13 排障加固（「盒子也连不上了」）
 *
 * 现象：盒子能扫到，但 `p2pConnect` 20 秒内不进 CONNECTED；现场 `p2p0` 网卡
 *   「UP 但无 IP」——既没当 GO 也没拿到 DHCP，是典型的 supplicant 残留半死状态。
 *
 * 三处加固：
 *   ① **连接前清残留**（`clearP2pState()`：p2pCancelConnect + removeGroup + 静默期）。
 *      盒子已被反复连过多次，残留组会让新的 GO 协商直接被拒。
 *   ② **失败后清理并重试一次**（P2P 首次协商偶发失败很常见，重试成本低收益高）。
 *   ③ **超时不再只说「超时」**，而是报出「卡在哪一步」：对端的 `deviceStatus`
 *      （INVITED / FAILED / 消失）+ 本机 linkedInfo 状态。见 `diagnoseFailure()`。
 *
 * 另新增 **同网段冲突预警**：盒子作 GO 时用 `192.168.0.0/24`，而家里路由器
 *   （HNJJDT）也是 `192.168.0.0/24` → `/proc/net/route` 里只认 wlan0 那条路由，
 *   P2P 一连就撞车（这是「能连上但老掉线」的头号原因）。此前这个失败模式
 *   **在界面上完全不可见**，现改为扫描/连接时直接告警。
 * ─────────────────────────────────────────────────────────────────────────
 */

import { wifiManager } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG = 'CarLifeWifiProbe';

/**
 * 单次系统调用的超时上限（毫秒）。
 *
 * 系统 P2P 接口的 Promise 有实测挂死（永不 resolve）的情况，
 * 不套超时会让整个连接流程永久卡住。3000ms 远大于正常响应时间，
 * 只会拦下真挂死的调用。
 */
const POLL_CALL_TIMEOUT_MS: number = 3000;

/** 清残留后的静默期：给 supplicant 时间把旧组真正拆干净 */
const P2P_SETTLE_MS: number = 800;

/**
 * ★ 盒子 GO 的网段 —— **不写死**（2026-10-14 大哥要求）。
 *
 * 历史做法是把 `192.168.0.` 写死当判据，那是基于「实测过一次盒子作 GO 用
 * 192.168.0.0/24」。问题很明显：
 *   - 盒子固件升级 / 换了盒子 / 换路由器，网段就可能变，写死就判错；
 *   - 判错的失败模式是「该报警时不报」，界面上根本看不出来。
 *
 * 现在改为**动态**：
 *   - 优先用「已连接 P2P 组报告的 GO IP」推出盒子网段（最可信，是实测值）；
 *   - 拿不到 P2P 组时，退化为「只报 STA 的实际网段 + 通用提示」，
 *     不再断言"一定和盒子冲突"，而是提醒用户"若连接异常请断家里 WiFi"。
 */
const FALLBACK_BOX_SUBNET: string = '192.168.0.';   // 仅在完全无信息时的兜底提示用

/** 单次 P2P 尝试的等待上限（毫秒）。共 4 种参数组合，最坏总耗时约 4 倍 */
const P2P_ATTEMPT_WAIT_MS: number = 12000;

/** 一次 P2P 连接尝试的参数组合 */
interface P2pAttempt {
  passphrase: string;
  band: wifiManager.GroupOwnerBand;
  /** GO 频率（MHz）；0 = 不指定，交给框架 */
  freq: number;
  /** 给日志/界面看的说明 */
  note: string;
}

/**
 * ★ P2P 连接尝试序列 —— 本项目此前**一直用错了参数**。
 *
 * 依据（2026-10-13 从官方手机端 `bdc_16031.apk` 里挖出的 proto 注释，原文照录）：
 *   `CarlifeWirlessTargetProto.proto`：
 *     // p2p ssid like "box, 88888888, 5745, 2" encrypted
 *     // p2p net info like "name,pwd"
 *   → 盒子的 P2P 组参数是「名字, **密码**, **频率**, **频段**」四元组：
 *     密码 `88888888`、频率 `5745` MHz、频段 `2`（= `GO_BAND_5GHZ`，与
 *     OpenHarmony 的 `GroupOwnerBand.GO_BAND_5GHZ = 2` 完全对应）。
 *
 * 本项目此前传的是 `passphrase: ''`（= WPS **PBC**）且不指定频段。
 * **盒子有密码时 PBC 必被拒**，表现就是「P2P 扫得到、但 20 秒也进不了
 * CONNECTED」—— 与真机实测症状完全吻合。5GHz/5745 也要对上，
 * 否则客户端会去 2.4G 找 GO 而找不到。
 *
 * 第 3 项 `12345678` 来自车机端 `CarLife4.0车机端.apk` 的 DEX 字符串常量。
 * 最后一项保留原来的 PBC 作兜底（万一盒子确实无密码）。
 *
 * 要改密码/频段只动这张表即可，无需碰连接逻辑。
 */
const P2P_ATTEMPTS: P2pAttempt[] = [
  {
    // ★ 2026-10-13 真机实测**成功**的这组，必须排第一。
    //
    //   实测记录（当天 10:26）：
    //     p2pConnect({ deviceAddress, netId: -1, passphrase: '',
    //                  groupName: '', goBand: GO_BAND_AUTO })
    //       → p2p CONNECTED → [WiFi自检] P2P 连接成功
    //     passLen=0 即**空串**，goBand 用 **AUTO**（不是 5GHz）。
    //
    //   ⚠ 曾经把它排在最后当"兜底"，前面塞了三组猜的参数 ——
    //     结果是前三组注定失败、每组白等十几秒，用户感受就是"连不上"。
    //     而且失败尝试会留残留状态污染后续。**成功参数就该排第一。**
    passphrase: '', band: wifiManager.GroupOwnerBand.GO_BAND_AUTO, freq: 0,
    note: '空串 + AUTO（2026-10-13 实测成功，首选）'
  },
  {
    passphrase: '88888888', band: wifiManager.GroupOwnerBand.GO_BAND_5GHZ, freq: 5745,
    note: '88888888 + 5GHz/5745（官方 proto 注释里的示例值）'
  },
  {
    passphrase: '88888888', band: wifiManager.GroupOwnerBand.GO_BAND_AUTO, freq: 0,
    note: '88888888，频段交给框架'
  },
  {
    passphrase: '12345678', band: wifiManager.GroupOwnerBand.GO_BAND_AUTO, freq: 0,
    note: '12345678（车机端 DEX 里的默认值）'
  }
];

/** 一个 P2P 对端 */
export interface P2pPeer {
  deviceName: string;
  deviceAddress: string;
  /**
   * `P2pDeviceStatus`：0=CONNECTED 1=INVITED 2=FAILED 3=AVAILABLE 4=UNAVAILABLE。
   * ★ 这是判断「协商卡在哪一步」的关键字段，此前被丢掉了。
   */
  deviceStatus: number;
  /** 组能力位（bit0 = 可作 GO，bit1 = 可作 client，bit2 = 需要 WPS 等） */
  groupCapabilities: number;
}

/** 一次 WiFi/P2P 探测的快照 */
export interface WifiProbeResult {
  /** 设备是否具备 SystemCapability.Communication.WiFi.P2P */
  supported: boolean;
  /** WLAN 总开关 */
  wifiActive: boolean;
  /** 当前 STA（普通 WiFi）连接的 SSID —— 用于判断手机此刻是否已连上盒子 */
  staSsid: string;
  /** 当前 STA 的 IPv4（点分十进制；拿不到为空串） */
  staIp: string;
  /** ★ 当前 STA 是否占用了与盒子 GO 相同的网段（true = 极可能连不上/掉线）
   *  判据是「STA 网段 vs 盒子 GO 实际网段」，**不写死任何网段**。 */
  subnetConflict: boolean;
  /** STA 的 IP 原始数值（判网段冲突用，不外显） */
  staIpRaw: number;
  /** 盒子 GO 的 IP（点分十进制；拿不到为空串） */
  boxIp: string;
  /** 当前是否已建立 P2P 连接 */
  p2pConnected: boolean;
  /** 本机是否为 GO（组主） */
  isGroupOwner: boolean;
  /** GO 的地址（未连接时为空） */
  groupOwnerAddr: string;
  /** 本机 P2P 设备名 / 地址 */
  localName: string;
  localAddr: string;
  /** 发现到的 P2P 对端 */
  peers: P2pPeer[];
  /** 非致命错误 */
  errors: string[];
}

export class WifiProbe {
  private static last: WifiProbeResult | null = null;

  /** 最近一次结果，未跑过为 null */
  static get latest(): WifiProbeResult | null {
    return WifiProbe.last;
  }

  /**
   * 跑一次 P2P 探测。
   *
   * @param discoverMs 发现时长（毫秒）。发现本质是「等对端回 probe response」，
   *                   太短会漏（GO 的 beacon 周期通常 100ms，但扫描窗口是跳频的），
   *                   太长没必要；6000ms 是个稳妥值。
   */
  static async probeP2p(discoverMs: number): Promise<WifiProbeResult> {
    const res: WifiProbeResult = {
      supported: false, wifiActive: false, staSsid: '', staIp: '',
      subnetConflict: false, staIpRaw: 0, boxIp: '',
      p2pConnected: false, isGroupOwner: false, groupOwnerAddr: '',
      localName: '', localAddr: '', peers: [], errors: []
    };

    // ---------- 0. 能力位（syscap） ----------
    // 本机 MRT-AL10 已实测含 Communication.WiFi.P2P；这里再自证一次，便于换机排查。
    try {
      res.supported = canIUse('SystemCapability.Communication.WiFi.P2P');
    } catch (e) {
      res.supported = false;
    }
    if (!res.supported) {
      res.errors.push('设备缺 SystemCapability.Communication.WiFi.P2P');
      WifiProbe.last = res;
      console.info(`${TAG} p2p supported=false`);
      return res;
    }

    // ---------- 1. WLAN 总开关 ----------
    try {
      res.wifiActive = wifiManager.isWifiActive();
    } catch (e) {
      const err = e as BusinessError;
      res.errors.push(`isWifiActive: ${err.message}`);
    }

    // ---------- 2. 当前 STA 连接（手机此刻连的是哪个 WiFi）----------
    // ★ 注意顺序：冲突判定要等下面拿到 P2P 组的 GO IP 才能做，
    //   所以这里只取 STA 信息，不留判据。
    try {
      const li: wifiManager.WifiLinkedInfo = await wifiManager.getLinkedInfo();
      res.staSsid = li.ssid;
      res.staIp = WifiProbe.ipv4ToString(li.ipAddress);
      res.staIpRaw = li.ipAddress;   // 留原始值给第 3b 步判冲突
      // 原始数值一并落日志：字节序踩过一次坑，留着它下次一眼就能验算
      console.info(`${TAG} sta ssid="${li.ssid}" ipAddress(raw)=${li.ipAddress} -> ${res.staIp === '' ? '-' : res.staIp}`);
    } catch (e) {
      const err = e as BusinessError;
      res.errors.push(`getLinkedInfo: ${err.message}`);
    }

    // ---------- 3. 当前 P2P 连接状态 ----------
    try {
      const p2p: wifiManager.WifiP2pLinkedInfo = await wifiManager.getP2pLinkedInfo();
      res.p2pConnected = (p2p.connectState === wifiManager.P2pConnectState.CONNECTED);
      res.isGroupOwner = p2p.isGroupOwner;
      res.groupOwnerAddr = p2p.groupOwnerAddr;
    } catch (e) {
      const err = e as BusinessError;
      res.errors.push(`getP2pLinkedInfo: ${err.message}`);
    }

    // ---------- 3b. 当前 P2P 组（GO 到底是谁 / 走哪个接口）+ ★动态网段冲突判定 ----------
    try {
      const g: wifiManager.WifiP2pGroupInfo = await wifiManager.getCurrentGroup();
      console.info(`${TAG} p2p currentGroup isGo=${g.isP2pGo}`
        + ` owner="${g.ownerInfo.deviceName}"@${g.ownerInfo.deviceAddress}`
        + ` iface=${g.interface} goIp=${g.goIpAddress} pskLen=${g.passphrase.length}`);

      // ★ 不写死网段：用**盒子 GO 的实际 IP** 和 STA 的 IP 比 /24。
      //   拿不到 GO IP（还没连上盒子）→ 不下冲突结论，只给通用提示。
      const boxIpRaw: number = WifiProbe.ipv4ToRaw(g.goIpAddress);
      res.boxIp = g.goIpAddress !== undefined && g.goIpAddress !== null
        ? String(g.goIpAddress) : '';
      res.subnetConflict = WifiProbe.isSubnetConflict(res.staIpRaw, boxIpRaw);
      if (res.subnetConflict) {
        console.warn(`${TAG} ⚠ STA(${res.staSsid} ${res.staIp}) 与盒子 GO(${res.boxIp}) 同网段，`
          + `P2P 会撞路由。测盒子前请先断开家里 WiFi。`);
      } else if (boxIpRaw === 0 && res.staIpRaw !== 0) {
        // 信息不足：不说"冲突"，只给通用提醒（写死网段的旧做法正是错在这里）
        console.info(`${TAG} 盒子 GO IP 暂不可得，无法判定网段冲突；`
          + `若扫描/连接异常，可尝试断开家里 WiFi（STA=${res.staIp}）`);
      }
    } catch (e) {
      const err = e as BusinessError;
      console.info(`${TAG} p2p currentGroup unavailable: ${err.message}`);
    }

    // ---------- 4. 本机 P2P 身份 ----------
    try {
      const me: wifiManager.WifiP2pDevice = await wifiManager.getP2pLocalDevice();
      res.localName = me.deviceName;
      res.localAddr = me.deviceAddress;
    } catch (e) {
      const err = e as BusinessError;
      res.errors.push(`getP2pLocalDevice: ${err.message}`);
    }

    // ---------- 5. 发起一轮发现 ----------
    try {
      wifiManager.startDiscoverDevices();
      console.info(`${TAG} p2p discover start, wait ${discoverMs}ms`);
    } catch (e) {
      const err = e as BusinessError;
      res.errors.push(`startDiscoverDevices: code=${err.code} ${err.message}`);
    }

    await WifiProbe.sleep(discoverMs);

    // ---------- 6. 取对端列表 ----------
    try {
      const devs: wifiManager.WifiP2pDevice[] = await wifiManager.getP2pPeerDevices();
      if (devs !== undefined && devs !== null) {
        for (let i = 0; i < devs.length; i++) {
          const d: wifiManager.WifiP2pDevice = devs[i];
          const p: P2pPeer = {
            deviceName: d.deviceName,
            deviceAddress: d.deviceAddress,
            deviceStatus: d.deviceStatus,
            groupCapabilities: d.groupCapabilities
          };
          res.peers.push(p);
        }
      }
    } catch (e) {
      const err = e as BusinessError;
      res.errors.push(`getP2pPeerDevices: ${err.message}`);
    }

    // ---------- 7. 停发现（省电，且避免长时间占用射频影响 STA 吞吐） ----------
    try {
      wifiManager.stopDiscoverDevices();
    } catch (e) {
      // 已停或未开，忽略
    }

    WifiProbe.last = res;

    // 单行汇总日志（便于 hilog 过滤）
    console.info(`${TAG} p2p supported=${res.supported} wifiActive=${res.wifiActive}`
      + ` staSsid="${res.staSsid}" staIp=${res.staIp === '' ? '-' : res.staIp}`
      + ` subnetConflict=${res.subnetConflict}`
      + ` p2pConnected=${res.p2pConnected} isGO=${res.isGroupOwner} goAddr=${res.groupOwnerAddr}`
      + ` local="${res.localName}" localAddr=${res.localAddr}`
      + ` peers=${res.peers.length} [${WifiProbe.joinPeers(res.peers)}]`
      + ` errors=${res.errors.join('|')}`);
    return res;
  }

  /**
   * 发起 P2P 连接。
   *
   * 流程：对 `P2P_ATTEMPTS` 里的每组参数依次「先清残留 → 连接 → 轮询等结果」，
   * 任一组成功即返回；全部失败则附上「卡在哪一步」的诊断。
   *
   * @param deviceAddress 目标 P2P 设备地址（来自 probeP2p 的 peers）
   * @param waitMs 单次尝试的最长等待毫秒数（最坏总耗时约为它 × 尝试组数）
   * @param onProgress 可选进度回调，用于界面显示「第几次尝试 / 用的哪组参数」
   * @returns 空串 = 连接成功；否则为失败原因（含卡在哪一步的诊断）
   */
  static async connectP2p(deviceAddress: string, waitMs: number,
                          onProgress?: (msg: string) => void): Promise<string> {
    // 已经连上了就别再折腾（本方法可能被重复点击触发）
    try {
      const li0: wifiManager.WifiP2pLinkedInfo =
        await WifiProbe.withTimeout(wifiManager.getP2pLinkedInfo(), POLL_CALL_TIMEOUT_MS, 'getP2pLinkedInfo');
      if (li0.connectState === wifiManager.P2pConnectState.CONNECTED) {
        console.info(`${TAG} p2p already CONNECTED, skip connect`);
        return '';
      }
    } catch (e) {
      // 读不到就当未连接，继续走正常流程
    }

    const per: number = waitMs > 0 ? waitMs : P2P_ATTEMPT_WAIT_MS;
    const failLog: string[] = [];
    let lastErr: string = '';

    for (let i = 0; i < P2P_ATTEMPTS.length; i++) {
      const a: P2pAttempt = P2P_ATTEMPTS[i];
      WifiProbe.notify(onProgress, `清理旧连接（第 ${i + 1}/${P2P_ATTEMPTS.length} 次尝试）...`);
      await WifiProbe.clearP2pState();

      WifiProbe.notify(onProgress, `第 ${i + 1}/${P2P_ATTEMPTS.length} 次：${a.note}`);
      lastErr = await WifiProbe.connectOnce(deviceAddress, a, per);
      if (lastErr === '') {
        console.info(`${TAG} p2p CONNECTED on attempt ${i + 1}: ${a.note}`);
        return '';
      }
      // ★ 累积每组的失败原因 —— 只报"4 次都失败"等于什么都没说，
      //   必须让用户/我看得出「哪组参数卡在哪一步」。
      const short: string = WifiProbe.shortenNote(a.note);
      failLog.push(`[${i + 1}] ${short} → ${lastErr}`);
      console.warn(`${TAG} p2p attempt ${i + 1} failed (${a.note}): ${lastErr}`);
      WifiProbe.notify(onProgress, `第 ${i + 1} 组失败：${lastErr}`);
    }

    // 全部尝试都失败 —— 把「每组卡在哪一步」一并报出去
    const diag: string = await WifiProbe.diagnoseFailure(deviceAddress);
    let msg: string = `P2P 连接失败（${P2P_ATTEMPTS.length} 组参数）`;
    msg += `｜${failLog.join('；')}`;
    if (diag !== '') {
      msg += `｜${diag}`;
    }
    console.error(`${TAG} ${msg}`);
    return msg;
  }

  /**
   * 单次连接尝试（不清理、不重试）。
   *
   * @returns 空串 = 成功；否则为失败原因
   */
  private static async connectOnce(deviceAddress: string, a: P2pAttempt,
                                   waitMs: number): Promise<string> {
    try {
      const cfg: wifiManager.WifiP2PConfig = {
        deviceAddress: deviceAddress,
        netId: -1, // -1 = 临时组（不持久化）
        passphrase: a.passphrase,
        groupName: '',
        goBand: a.band
      };
      // goFreq 是 @since 23 的可选字段，只有明确知道 GO 频率时才设置；
      // 设 0 或不设都表示「交给框架」，但显式设 0 在老实现上可能被判非法参数。
      if (a.freq > 0) {
        cfg.goFreq = a.freq;
      }
      wifiManager.p2pConnect(cfg);
      console.info(`${TAG} p2pConnect issued addr=${deviceAddress}`
        + ` pwdLen=${a.passphrase.length} band=${a.band} freq=${a.freq}`);
    } catch (e) {
      const err = e as BusinessError;
      const msg: string = `p2pConnect 调用失败: code=${err.code} ${err.message}`;
      console.error(`${TAG} ${msg}`);
      return msg;
    }

    // 轮询等待结果（比常驻 p2pConnectionChange 回调简单可靠，且同样只需 GET_WIFI_INFO）
    //
    // ⚠ 每个系统调用都要套超时：2026-10-13 实测踩到过一次
    //   `getP2pLinkedInfo()` 的 Promise **永不 resolve** —— 循环卡死在 await 上，
    //   `connectP2p()` 永不返回，界面上「连接」按钮就永远停在「处理中...」，
    //   日志里也只会留下 `连接 Wi-Fi Direct 设备 ...` 一行、没有任何结果行。
    //   套上超时后，最坏情况变成「本轮轮询失败、继续下一轮」，到点正常报超时。
    const deadline: number = Date.now() + waitMs;
    while (Date.now() < deadline) {
      await WifiProbe.sleep(1000);
      try {
        const li: wifiManager.WifiP2pLinkedInfo =
          await WifiProbe.withTimeout(wifiManager.getP2pLinkedInfo(), POLL_CALL_TIMEOUT_MS, 'getP2pLinkedInfo');
        if (li.connectState === wifiManager.P2pConnectState.CONNECTED) {
          let iface: string = '';
          let groupPskLen: number = 0;
          let goIp: string = '';
          try {
            const g: wifiManager.WifiP2pGroupInfo =
              await WifiProbe.withTimeout(wifiManager.getCurrentGroup(), POLL_CALL_TIMEOUT_MS, 'getCurrentGroup');
            iface = g.interface;
            groupPskLen = g.passphrase.length;
            goIp = g.goIpAddress;
          } catch (e2) {
            // 组信息拿不到不影响「已连接」这一判定
          }
          console.info(`${TAG} p2p CONNECTED isGO=${li.isGroupOwner}`
            + ` goAddr=${li.groupOwnerAddr} iface=${iface} goIp=${goIp} groupPskLen=${groupPskLen}`);
          return '';
        }
      } catch (e) {
        // 轮询期间的瞬时错误 / 超时忽略，继续等
      }
    }
    return `P2P 连接超时（${waitMs}ms 内未进入 CONNECTED）`;
  }

  /**
   * 失败后收集「卡在哪一步」的证据。
   *
   * 为什么要这个：只报「超时」等于什么都没说 —— 到底是盒子没回应（对端从列表消失）、
   * 协商被拒（对端 FAILED）、还是邀请发出后卡住（对端 INVITED），
   * 三种情况对应的处置完全不同。
   */
  private static async diagnoseFailure(deviceAddress: string): Promise<string> {
    const parts: string[] = [];

    try {
      const li: wifiManager.WifiP2pLinkedInfo =
        await WifiProbe.withTimeout(wifiManager.getP2pLinkedInfo(), POLL_CALL_TIMEOUT_MS, 'getP2pLinkedInfo');
      const st: string = li.connectState === wifiManager.P2pConnectState.CONNECTED ? 'CONNECTED' : 'DISCONNECTED';
      parts.push(`本机P2P=${st}`);
    } catch (e) {
      parts.push('本机P2P=读取超时');
    }

    try {
      const devs: wifiManager.WifiP2pDevice[] = await wifiManager.getP2pPeerDevices();
      let found: boolean = false;
      for (let i = 0; i < devs.length; i++) {
        if (devs[i].deviceAddress.toLowerCase() === deviceAddress.toLowerCase()) {
          parts.push(`对端状态=${WifiProbe.deviceStatusName(devs[i].deviceStatus)}`);
          found = true;
        }
      }
      if (!found) {
        parts.push('对端已从列表消失（盒子可能掉电或退出了 P2P 模式）');
      }
    } catch (e) {
      // 诊断失败不影响主结论
    }

    return parts.join(' ');
  }

  /**
   * 清掉残留的 P2P 组与进行中的连接请求。
   *
   * 为什么需要：盒子已被反复连过多次，且中途出现过应用被杀 / hdc 掉线，
   * 现场 `p2p0` 网卡呈「UP 但无 IP」的半死状态。不清残留就直接 p2pConnect，
   * 新的 GO 协商很容易被 supplicant 直接拒掉（表现为「扫得到但永远连不上」）。
   */
  private static async clearP2pState(): Promise<void> {
    // 有进行中的连接先取消；没有的话会报错，忽略
    try {
      wifiManager.p2pCancelConnect();
    } catch (e) {
      // 忽略
    }
    // 再拆组；本来就没组也会报错，忽略
    try {
      wifiManager.removeGroup();
    } catch (e) {
      // 忽略
    }
    await WifiProbe.sleep(P2P_SETTLE_MS);
  }

  /**
   * 断开当前 P2P 连接并移除组。
   *
   * @returns 空串 = 正常；否则为失败原因
   */
  static async disconnectP2p(): Promise<string> {
    let errMsg: string = '';
    try {
      wifiManager.removeGroup();
      console.info(`${TAG} p2p removeGroup issued`);
    } catch (e) {
      const err = e as BusinessError;
      errMsg = `removeGroup: code=${err.code} ${err.message}`;
      console.error(`${TAG} ${errMsg}`);
    }
    // 若当时正在建立连接，再取消一次；没有进行中的连接会报错，忽略即可
    try {
      wifiManager.p2pCancelConnect();
    } catch (e) {
      // 忽略
    }
    return errMsg;
  }

  /** 把结果拼成可读的多行文本（给日志 / UI 用） */
  static format(r: WifiProbeResult): string[] {
    const lines: string[] = [];
    lines.push(`[WiFi探测] P2P能力=${r.supported} WLAN开关=${r.wifiActive}`
      + ` 当前SSID="${r.staSsid}" IP=${r.staIp === '' ? '-' : r.staIp}`);
    if (r.subnetConflict) {
      lines.push(`[WiFi探测] ⚠ 当前 WiFi(${r.staIp}) 与盒子 GO(${r.boxIp}) 同网段`
        + ` —— 会撞路由导致连不上/掉线，请先断开家里 WiFi 再连盒子`);
    }
    lines.push(`[WiFi探测] P2P连接=${r.p2pConnected} 本机是GO=${r.isGroupOwner}`
      + ` GO地址=${r.groupOwnerAddr === '' ? '-' : r.groupOwnerAddr}`);
    lines.push(`[WiFi探测] 本机P2P名="${r.localName}" 地址=${r.localAddr}`);
    lines.push(`[WiFi探测] P2P对端(${r.peers.length}): ${WifiProbe.joinPeers(r.peers)}`);
    if (r.errors.length > 0) {
      lines.push(`[WiFi探测] 异常(${r.errors.length}): ${r.errors.join(' | ')}`);
    }
    return lines;
  }

  /** `P2pDeviceStatus` 数值转名字 */
  static deviceStatusName(s: number): string {
    if (s === 0) { return 'CONNECTED'; }
    if (s === 1) { return 'INVITED'; }
    if (s === 2) { return 'FAILED'; }
    if (s === 3) { return 'AVAILABLE'; }
    if (s === 4) { return 'UNAVAILABLE'; }
    return `?(${s})`;
  }

  /** 对端列表转一行文本（带状态，便于看出协商卡在哪一步） */
  private static joinPeers(peers: P2pPeer[]): string {
    if (peers.length === 0) {
      return '无';
    }
    const parts: string[] = [];
    for (let i = 0; i < peers.length; i++) {
      parts.push(`"${peers[i].deviceName}"@${peers[i].deviceAddress}`
        + `[${WifiProbe.deviceStatusName(peers[i].deviceStatus)}]`);
    }
    return parts.join('; ');
  }

  /**
   * 判断「STA 当前网段」与「盒子 GO 网段」是否冲突。
   *
   * ★ 不写死网段（2026-10-14 改造）：
   *   - `boxIpRaw` 有值（能拿到 P2P 组的 GO IP）→ 用**它的实际网段**比对，最可信；
   *   - `boxIpRaw` 为 0（还没连上盒子，拿不到 GO IP）→ **无法断定冲突**，
   *     返回 false，由调用方给「通用提示」而不是硬说"冲突"。
   *
   * 为什么这样更好：写死 192.168.0 只能在"盒子恰好用这个网段"时正确，
   * 而且判错的代价是**漏报**（该提醒时不提醒），界面上看不见。
   */
  private static isSubnetConflict(staIp: number, boxIpRaw: number): boolean {
    if (staIp === 0 || boxIpRaw === 0) {
      return false;   // 信息不足 → 不下冲突结论
    }
    // 取前 24 位（/24 网段）比较。字节序两种都试，避免踩端序坑。
    const be = (v: number): number => ((v >>> 8) & 0xffffff) >>> 0;   // 大端：去末 8 位
    const le = (v: number): number => (v & 0xffffff) >>> 0;           // 小端：去高 8 位
    return be(staIp) === be(boxIpRaw) || be(staIp) === le(boxIpRaw)
        || le(staIp) === be(boxIpRaw) || le(staIp) === le(boxIpRaw);
  }

  /**
   * 已废弃：旧的写死网段判断。保留仅供对照，勿再调用。
   * @deprecated 改用 isSubnetConflict(staIp, boxIpRaw)
   */
  private static isBoxSubnet(ip: number): boolean {
    if (ip === 0) { return false; }
    const a: number = ip & 0xff;
    const b: number = (ip >>> 8) & 0xff;
    const c: number = (ip >>> 16) & 0xff;
    const d: number = (ip >>> 24) & 0xff;
    // 大端（实测如此）：d.c.b.a ；小端（Android 约定）：a.b.c.d
    return (d === 192 && c === 168 && b === 0) || (a === 192 && b === 168 && c === 0);
  }

  /** note → 短标签（用在失败摘要里，太长会撑爆提示行） */
  private static shortenNote(note: string): string {
    if (note.indexOf('空串') >= 0) { return '空串'; }
    if (note.indexOf('88888888') >= 0 && note.indexOf('5GHz') >= 0) { return '88888888@5G'; }
    if (note.indexOf('88888888') >= 0) { return '88888888'; }
    if (note.indexOf('12345678') >= 0) { return '12345678'; }
    return note.length > 12 ? note.slice(0, 12) : note;
  }

  /**
   * `goIpAddress`（可能是点分十进制字符串 或 数值）→ 原始数值。
   *
   * 为什么需要：`WifiP2pGroupInfo.goIpAddress` 的类型在不同 API 版本里
   * 出现过 string / number 两种，这里统一转成 number 以便按位比较网段。
   * 解析失败返回 0（调用方据此判定"信息不足"）。
   */
  private static ipv4ToRaw(v: string | number | undefined | null): number {
    if (v === undefined || v === null) { return 0; }
    if (typeof v === 'number') { return v >>> 0; }
    const parts: string[] = String(v).split('.');
    if (parts.length !== 4) { return 0; }
    let out: number = 0;
    for (let i = 0; i < 4; i++) {
      const n: number = Number(parts[i]);
      if (isNaN(n) || n < 0 || n > 255) { return 0; }
      out = ((out << 8) | n) >>> 0;
    }
    return out >>> 0;
  }

  /**
   * `ipAddress` 数值 → 点分十进制。
   *
   * ★ 字节序已实测确证为**大端**（高字节 = 第一段）：
   *   2026-10-13 真机实测，wlan0 = 192.168.0.186 时 `getLinkedInfo().ipAddress`
   *   的数值对应 `0xC0A800BA` → 按大端解出 `192.168.0.186`，与小端约定（Android
   *   的 `WifiInfo.getIpAddress()`）**相反**。
   *   曾按小端写，输出 `186.0.168.192` —— 数值本身就是证据，别改回去。
   */
  private static ipv4ToString(ip: number): string {
    if (ip === 0) { return ''; }
    const a: number = (ip >>> 24) & 0xff;
    const b: number = (ip >>> 16) & 0xff;
    const c: number = (ip >>> 8) & 0xff;
    const d: number = ip & 0xff;
    return `${a}.${b}.${c}.${d}`;
  }

  /** 有回调就调，没有就算了 */
  private static notify(cb: ((msg: string) => void) | undefined, msg: string): void {
    if (cb !== undefined) {
      cb(msg);
    }
  }

  /**
   * 给可能挂死的系统 Promise 套一层超时。
   *
   * 为什么需要：系统 P2P 接口的 Promise 实测出现过**永不 resolve**，
   * 一旦 `await` 上去，调用方就永久卡住（按钮停在「处理中...」、无任何结果日志）。
   * 套上超时后最坏情况退化为「本次调用失败」，循环能继续推进。
   */
  private static withTimeout<T>(p: Promise<T>, ms: number, tag: string): Promise<T> {
    return new Promise<T>((resolve: (v: T) => void, reject: (e: Error) => void) => {
      let settled: boolean = false;
      setTimeout(() => {
        if (!settled) {
          settled = true;
          reject(new Error(`${tag} 超时（${ms}ms 未返回）`));
        }
      }, ms);
      p.then((v: T) => {
        if (!settled) {
          settled = true;
          resolve(v);
        }
      }).catch((e: Error) => {
        if (!settled) {
          settled = true;
          reject(e);
        }
      });
    });
  }

  /** 等待若干毫秒 */
  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => resolve(), ms);
    });
  }
}
