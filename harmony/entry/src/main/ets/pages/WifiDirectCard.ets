/**
 * Wi-Fi 直连（Wi-Fi Direct / P2P）卡片
 *
 * 背景：
 *   鸿蒙设置里**已经没有「WLAN 直连」入口**（HarmonyOS 5 起取消，2026-10-13 实测设置应用
 *   39 个 Ability 中无任何 p2p/direct/wlan 页面）。所以要让手机连上车联盒子 QH3002
 *   这类 Wi-Fi Direct 设备，**只能靠应用自己调系统 P2P 接口**。
 *
 *   实测结论（真机 nova 14 Ultra / HarmonyOS 7.0.0.109）：
 *     - 盒子以 **`Box_259E`** 出现在 P2P 发现结果里（**不在**普通 WLAN 列表，扫 WiFi 找不到它）
 *     - `p2pConnect()` 的 `passphrase` **传空串即可**（盒子无密码，框架自动协商）
 *     - 全套 P2P 接口只需 `ohos.permission.GET_WIFI_INFO`（normal / system_grant），
 *       **不需要位置权限**
 *
 * 本卡片职责：把上述能力做成用户可操作的功能 —— 扫描 / 连接 / 断开。
 *
 * 2026-10-13 补充：把「同网段冲突」这个**此前完全不可见的失败原因**显式告警出来。
 *   盒子作 GO 用 192.168.0.0/24，家里路由器也是 192.168.0.0/24 →
 *   内核只认 wlan0 那条路由，P2P 一连就撞车。这就是「能连上但老掉线」的头号原因。
 */

import { WifiProbe, WifiProbeResult, P2pPeer } from '../core/WifiProbe';
import { CarLifeRuntime } from '../entryability/EntryAbility';

/** P2P 发现时长（毫秒）：太短会漏对端，6000 是实测可用的稳妥值 */
const P2P_SCAN_MS: number = 6000;
/**
 * 单次连接尝试的等待上限（毫秒）。
 *
 * 连接会按 `WifiProbe.P2P_ATTEMPTS` 里的多组参数（密码/频段）依次尝试，
 * 故最坏总耗时 ≈ 本值 × 组数。
 */
const P2P_CONNECT_WAIT_MS: number = 12000;

@Component
export struct WifiDirectCard {
  /** 设备是否具备 P2P 能力（只有扫过才知道，扫之前是未知而不是"不支持"） */
  @State supported: boolean = false;
  /** 是否已经扫过至少一次 —— 用来区分「未扫描」和「本机不支持」 */
  @State scanned: boolean = false;
  /** 当前是否已建立 P2P 连接 */
  @State connected: boolean = false;
  /** 已连接的对端名字（用于界面显示） */
  @State connectedName: string = '';
  /** 发现到的 P2P 对端 */
  @State peers: P2pPeer[] = [];
  /** 正在扫描 / 连接 / 断开 */
  @State busy: boolean = false;
  /** 提示文案 */
  @State hint: string = '未扫描。点「扫描设备」查找车联盒子。';
  /** ★ 当前普通 WiFi 是否占用了与盒子相同的网段（会导致连不上/掉线） */
  @State subnetConflict: boolean = false;
  /** 当前普通 WiFi 的 SSID（告警里要说清是哪个网要断开） */
  @State staSsid: string = '';

  build() {
    Column({ space: 8 }) {
      Text('Wi-Fi 直连')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor('#8B949E')
        .width('100%')

      // ---------- 状态行 ----------
      Row() {
        Circle({ width: 8, height: 8 })
          .fill(this.connected ? '#3FB950'
            : (this.scanned && this.supported ? '#D29922' : '#484F58'))
        Text(this.connected
          ? (this.connectedName !== '' ? `已连接（${this.connectedName}）` : '已连接')
          : (this.scanned ? (this.supported ? '未连接' : '本机不支持 Wi-Fi Direct') : '未扫描'))
          .fontSize(13)
          .fontColor(this.connected ? '#3FB950' : '#8B949E')
          .margin({ left: 8 })
      }
      .width('100%')

      // ---------- ★ 同网段冲突告警（连不上/老掉线的头号原因，必须显眼） ----------
      if (this.subnetConflict) {
        Column({ space: 3 }) {
          Text('⚠ 网段冲突：连不上 / 老掉线多半是这个')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor('#F85149')
            .width('100%')
          Text(`手机当前连的 WiFi「${this.staSsid === '' ? '未知' : this.staSsid}」`
            + `用的是 192.168.0.x，和盒子同网段。请先断开家里 WiFi 再连盒子。`)
            .fontSize(11)
            .fontColor('#D29922')
            .width('100%')
        }
        .width('100%')
        .padding(8)
        .backgroundColor('#2D1618')
        .border({ width: 1, color: '#F85149', radius: 8 })
        .alignItems(HorizontalAlign.Start)
      }

      Text(this.hint)
        .fontSize(12)
        .fontColor('#8B949E')
        .width('100%')

      // ---------- 扫描 ----------
      Button(this.busy ? '处理中...' : '扫描设备')
        .fontSize(14)
        .height(34)
        .width('100%')
        .backgroundColor('#21262D')
        .enabled(!this.busy)
        .onClick(() => {
          this.doScan();
        })

      // ---------- 对端列表 ----------
      ForEach(this.peers, (peer: P2pPeer) => {
        Row() {
          Column({ space: 2 }) {
            Text(peer.deviceName)
              .fontSize(13)
              .fontColor('#C9D1D9')
              .width('100%')
              .textAlign(TextAlign.Start)
            Text(`${peer.deviceAddress} · ${WifiProbe.deviceStatusName(peer.deviceStatus)}`)
              .fontSize(11)
              .fontColor('#6E7681')
              .width('100%')
              .textAlign(TextAlign.Start)
          }
          .layoutWeight(1)

          Button('连接')
            .fontSize(13)
            .height(30)
            .backgroundColor('#1F6FEB')
            .fontColor('#FFFFFF')
            .enabled(!this.busy)
            .onClick(() => {
              this.doConnect(peer);
            })
        }
        .width('100%')
        .padding({ top: 4, bottom: 4 })
      }, (peer: P2pPeer) => peer.deviceAddress)

      // ---------- 断开 ----------
      if (this.connected) {
        Button('断开连接')
          .fontSize(14)
          .height(34)
          .width('100%')
          .backgroundColor('#21262D')
          .enabled(!this.busy)
          .onClick(() => {
            this.doDisconnect();
          })
      }

      Text('车联盒子会以 Box_ 开头的名字出现，不需要密码。扫不到就先确认盒子已通电。'
        + '鸿蒙设置里已无「WLAN 直连」入口，只能由本应用直接调系统 P2P 接口。')
        .fontSize(11)
        .fontColor('#6E7681')
        .width('100%')
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#161B22')
    .border({ width: 1, color: '#21262D', radius: 10 })
    .alignItems(HorizontalAlign.Start)
  }

  /** 扫描一轮 P2P 设备 */
  private async doScan(): Promise<void> {
    this.busy = true;
    this.hint = '扫描中（约 6 秒）...';
    CarLifeRuntime.addLog('开始扫描 Wi-Fi Direct 设备...');
    try {
      const r: WifiProbeResult = await WifiProbe.probeP2p(P2P_SCAN_MS);
      const lines: string[] = WifiProbe.format(r);
      for (let i = 0; i < lines.length; i++) {
        CarLifeRuntime.addLog(lines[i]);
      }
      this.scanned = true;
      this.supported = r.supported;
      this.connected = r.p2pConnected;
      this.peers = r.peers;
      this.subnetConflict = r.subnetConflict;
      this.staSsid = r.staSsid;
      if (!r.supported) {
        this.hint = '本机不具备 Wi-Fi Direct 能力';
      } else if (r.peers.length > 0) {
        this.hint = `发现 ${r.peers.length} 个设备`;
      } else {
        this.hint = '未发现 P2P 设备（盒子是否已通电？）';
      }
    } catch (e) {
      const err = e as Error;
      this.hint = `扫描失败: ${err.message}`;
      CarLifeRuntime.addLog(`P2P 扫描失败: ${err.message}`);
    } finally {
      this.busy = false;
    }
  }

  /** 连接指定对端 */
  private async doConnect(peer: P2pPeer): Promise<void> {
    this.busy = true;
    this.hint = `正在连接 ${peer.deviceName} ...`;
    CarLifeRuntime.addLog(`连接 Wi-Fi Direct 设备 ${peer.deviceName} @${peer.deviceAddress}...`);
    try {
      // 进度回调：把「清残留 / 第几次尝试」实时显示出来，
      // 否则一次连接最长要等 40 秒，界面却一直只有一句「正在连接」，看起来像卡死。
      const onProgress = (msg: string): void => {
        this.hint = `${peer.deviceName}：${msg}`;
        CarLifeRuntime.addLog(`[P2P] ${msg}`);
      };
      const err: string = await WifiProbe.connectP2p(peer.deviceAddress, P2P_CONNECT_WAIT_MS, onProgress);
      if (err === '') {
        this.connected = true;
        this.connectedName = peer.deviceName;
        this.hint = `已连接 ${peer.deviceName}`;
        CarLifeRuntime.addLog(`Wi-Fi Direct 已连接 ${peer.deviceName}`);
      } else {
        this.hint = `连接失败：${err}`;
        CarLifeRuntime.addLog(`Wi-Fi Direct 连接失败：${err}`);
      }
    } catch (e) {
      const err = e as Error;
      this.hint = `连接异常: ${err.message}`;
      CarLifeRuntime.addLog(`Wi-Fi Direct 连接异常: ${err.message}`);
    } finally {
      this.busy = false;
    }
  }

  /** 断开当前 P2P 连接 */
  private async doDisconnect(): Promise<void> {
    this.busy = true;
    this.hint = '正在断开...';
    try {
      const err: string = await WifiProbe.disconnectP2p();
      this.connected = false;
      this.connectedName = '';
      this.hint = err === '' ? '已断开' : `断开时出错：${err}`;
      CarLifeRuntime.addLog(`Wi-Fi Direct ${this.hint}`);
    } catch (e) {
      const err = e as Error;
      this.hint = `断开异常: ${err.message}`;
    } finally {
      this.busy = false;
    }
  }
}
