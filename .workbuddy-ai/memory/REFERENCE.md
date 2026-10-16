# CarHi 参考手册（按需查阅）

`MEMORY.md` 的配套深挖文档。只放速查表与细节，不放每轮都要知道的铁律。

## A. 关键 ID 速查（官方值）

```
98305 HU_PROTOCOL_VERSION        65538 MD_MATCH_STATUS        98307 HU_INFO
65540 MD_INFO                    98343 STATISTIC_INFO         65609 MD_AUTHEN_RESPONSE
65611 MD_AUTHEN_RESULT           98376 HU_AUTHEN_REQUEST      98378 HU_AUTHEN_RESULT
65617 MD_FEATURE_CONFIG_REQUEST  98386 HU_FEATURE_CONFIG_RESPONSE
98311 HU_VIDEO_ENCODER_INIT      65544 VIDEO_ENCODER_INIT      98313 VIDEO_ENCODER_START
65551 VIDEO_ENCODER_INIT_DONE    131073 VIDEO_DATA
65560 SCREEN_ON                  65561 SCREEN_OFF             65562 SCREEN_USERPRESENT
65563 FOREGROUND                 65564 BACKGROUND             65574 MODULE_STATUS
131074 VIDEO_HEARTBEAT
```

`/proc/net/tcp` hex 端口：`1C48`=7240 `2030`=8240 `2418`=9240 `2419`=9241 `241A`=9242
`247C`=9340 `24E0`=9440；状态 `0A`=LISTEN `01`=ESTABLISHED。

## B. 三条连接路线（完整证据）

| 路线 | 载体 | 证据 | 状态 |
|---|---|---|---|
| A. Wi-Fi Direct | P2P + 7 个 TCP 端口 | `WifiProbe.ets` 已实现 | 能发现 `Box_259E`，未连成 |
| B. 搜索蓝牙配对 | BLE 广播 + 经典蓝牙 SPP | 官方 MD/车机端均有 `BluetoothClient`/`BluetoothConnect`/`BluetoothWirlessHelper`；RFCOMM/SPP UUID `00001101-0000-1000-8000-00805F9B34FB`；`createRfcommSocketToServiceRecord` / `listenUsingRfcommWithServiceRecord`；BLE 侧 `BleBluetoothManager`/`BleBluetoothDiscover`；`TAG_BOX_BLE_MAC` / `saveBoxMac2Local` / `isWifiP2pByBox` | 未实现 |
| C. ADB over IP + scrcpy | `com.baidu.supercast.link`（完整 AdbLib：`AdbConnection`/`AdbProtocol`/`AdbStream`/`UsbADBConnectionManager`、`AdbMdns` 发现 `_adb._tcp`、`LinkGo.checkTcpIpPort`）、`com.baidu.supercast.display.ScrcpyProvider` | 小米/vivo CarWith 模式走这条；字符串 `Try to bring Carlife to foreground via adb command used by XiaoMi`、`com.miui.carlink`、`com.vivo.car.action.adb.view` | 未实现 |

协议层无线相关消息：`MSG_WIRLESS_INFO_REQUEST/RESPONSE`、`MSG_WIRLESS_REQUEST_IP/RESPONSE_IP`、
`MSG_WIRLESS_TARGETINFO_REQUEST/RESPONSE`、`MSG_WIRLESS_HU_STATUS/MD_STATUS`、`KEY_WIRLESS_CONNECT_TYPE`、`bluewirless`。
BLE 流程字符串：`by ble scanRecord,index = `、`copyOfRange(scanRecord, index + 1, index + length)`、
`md start p2p connect, scanRecord: `、`p2pNetInfo parts=`。

官方手机端 `bdc_16031.apk` AndroidManifest 关键声明：
`android.hardware.usb.action.USB_ACCESSORY_ATTACHED`（AOA）、
`BLUETOOTH / BLUETOOTH_ADMIN / BLUETOOTH_ADVERTISE / BLUETOOTH_CONNECT / BLUETOOTH_SCAN`。

## C. 盒子后台（Web 管理页）

- 主地址 `http://192.168.0.1`（厂商教程口径；备选 `http://192.168.1.101`、`http://192.168.50.1`）。
  与实测吻合：盒子作 GO、手机 `192.168.0.2/24` → **GO 就是 192.168.0.1**。
- **三个硬前提**：① 盒子插**普通 USB 充电器**（不插车机）、上电等 ~5 分钟；② 手机**必须连盒子自己的
  WiFi/直连**（连家里 WiFi 无效）；③ **老固件没有后台**。
- P2P 场景下要先断家里 WiFi，或用 `TCPSocket.bind('192.168.0.2')` 绑 P2P 网卡绕开路由冲突。
- 固件 V0.2.7 的「搜索蓝牙配对」与「自动弹窗/BLE」两模式**互斥**，在此后台切换。

## D. Wi-Fi Direct 细节

- 连接流程：`startDiscoverDevices()` → 等 6s → `getP2pPeerDevices()` → `p2pConnect(...)` →
  轮询 `getP2pLinkedInfo().connectState === CONNECTED`。单次等待 `P2P_ATTEMPT_WAIT_MS = 12000`。
- **权限**：P2P 全套只需 `ohos.permission.GET_WIFI_INFO`（normal/system_grant），**不需要位置权限
  → 锁屏也能跑**（可远程 `aa start` 触发自检）。
- **判据陷阱**：`getP2pLinkedInfo().groupOwnerAddr` 恒 `00.00.00.00`；
  `getP2pLocalDevice().deviceAddress` 因缺 `GET_WIFI_LOCAL_MAC` 恒全 0 —— 均属预期，不可作判据。
- **扫不到 `Box_` 开头设备 = 盒子没通电或不在 P2P 模式**（曾只扫到惠普打印机
  `DIRECT-A5-HP Smart Tank 530`）。报「P2P 连接超时」时先看扫描结果里有没有 `Box_`。
- **★ 系统 P2P 接口的 Promise 会挂死**：`getP2pLinkedInfo()` 实测永不 resolve → 按钮永远「处理中...」。
  `WifiProbe.withTimeout()`（`POLL_CALL_TIMEOUT_MS = 3000`）是必须的护栏。
- **★ `ipv4ToString()` 字节序是「大端」**：实测 `ipAddress(raw)=3232235706` = `0xC0A800BA`
  → `192.168.0.186`，与 Android `WifiInfo.getIpAddress()` 的**小端约定相反**。数值本身就是证据，别改回去。
- 网段冲突实测数据：手机 P2P 口 `p2p-p2p0-4` = `192.168.0.2/24`；盒子 GO 用 `192.168.0.0/24`；
  家里路由器 `HNJJDT` = `192.168.0.0/24`（手机 wlan0 `192.168.0.186`）。
  `/proc/net/route` 里没有 p2p 路由，`192.168.0.1` 的 ARP 指向家里路由器 `b4:0f:3b:70:11:50`。
- 代码：`core/WifiProbe.ets`、`pages/WifiDirectCard.ets`；`EntryAbility.AUTO_WIFI_SELFCHECK` 默认 false。

## E. 界面（`pages/Index.ets`）

自上而下：**状态**（服务/握手/保活/录屏授权 2×2 指示灯）→ **主操作按钮** → **推流** →
**Wi-Fi 直连**（`WifiDirectCard`）→ **通道**（一行 7 个灯 + 已连接 N/7）→ **运行日志**。
已移除「USB 直连诊断 / AOA 试连」整块卡片（`core/UsbProbe.ets` 文件保留，`AUTO_USB_SELFCHECK=false`）。

## F. `tools/static_check.mjs` 的 5 处 DIFF

依赖 `refs/carlife_pc_tool`（gitignored，不跨机同步）。自 2026-10-12 按官方 `CommonParams` 修正后报
5 处 DIFF：HU_AUTHEN_RESULT `98378/98380`、MD_FOREGROUND `65563/65560`、MD_BACKGROUND `65564/65561`、
VIDEO_ENCODER_PAUSE `98314/98316`、VIDEO_ENCODER_RESET `98315/98311`
—— **属参考值过时，非代码错**。其中 **98378 vs 98380 两份逆向结论冲突**，本机无裁决依据。

## G. 本机工具限制与 APK 分析手法

- **PowerShell 工具调用返回空**（exit 0 无 stdout）→ 需 `Out-File` 到临时文件再 Read。
- `reg.exe` 被**安全策略拉黑**；`pnputil /enum-devices` 只打印帮助；Bash 调 `powershell -Command` 被拦。
- `strings` 命令在本环境**不可用**（输出为空）→ 改用 Python 正则 `rb'[\x20-\x7e]{5,}'` 提字符串。
- **jadx 下载屡次失败**（GitHub release 多次截断，ZIP 校验不过）→ 全部改用
  `unzip` + Python 字符串提取 + 自写 AXML / `resources.arsc` 解析。
- **AXML 解析要点**：`string pool` chunk 从 offset **8** 开始，**不是** `header.size`(12)；
  否则报 `stringPool at <越界>`。本机 APK 的 string pool 是 **UTF-16LE**（`utf8=False`）。
- **Grep 工具看不到 `/tmp`**：Bash 的 `/tmp` 映射到 `C:/Users/dev/AppData/Local/Temp`，
  需用 `pwd -W` 取 Windows 路径再传给 Grep。
- hdc 路径：`E:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe`（**不在 PATH**）。
- **★ 本 App 的 `console.info` tag 是 `CarHi`、domain 是 `A00001`** —— 完整形如
  `A00001/com.carhi.carlifephone/CarHi: ...`。**不是** `A03D00/.../JSAPP`
  （那是别的应用的 JS 日志，按 `JSAPP` 过滤会**一条都抓不到**本 App 的日志）。
- `hilog -x` 只是转储当前缓冲，**轮转极快**（约 8000 行，几秒就被系统日志刷掉），
  必须「边做动作边抓」。已验证的可靠姿势（**不会留下空转烧 CPU 的进程**）：
  ```
  hdc shell "rm -f /data/local/tmp/x.log; nohup timeout 20 hilog > /data/local/tmp/x.log 2>&1 &"
  # …做动作…
  hdc shell "grep -a A00001/com.carhi.carlifephone/CarHi /data/local/tmp/x.log"
  ```
  `timeout` 保证 hilog 进程自杀；收工后 `ps -ef | grep hilog` 应只剩系统 `hilogd`。
- UI 自动化：`uitest dumpLayout -p <path>` + `hdc file recv`（本地路径需 `MSYS_NO_PATHCONV=1` 且先 `cd`）；
  ★ **点之前必须先 dump 确认前台是 CarHi**（曾误点进微信）。

## H. 官方 proto 字段表（易错项）

`CarlifeDeviceInfoProto.proto`（65540 用）：
`os=1 board=2 bootloader=3 brand=4 cpu_abi=5 cpu_abi2=6 device=7 display=8 fingerprint=9
hardware=10 host=11 cid=12 manufacturer=13 model=14 product=15 serial=16 codename=17
incremental=18 release=19 sdk=20 sdk_int=21 **token=22** btaddress=23 **carlifeversion=24**
carlifeType=25 year=26 carlifeSdkInt=27`（全部 optional）。

`CarlifeFeatureConfigListProto.proto`：`cnt=1(required) featureConfig=2(repeated)
huBtAudioSupport=3 huBtName=4 huBtMAC=5` —— 带 `huBt*` 说明它是 **HU→MD 响应（98386）** 的载荷，
不是 65617 请求的载荷；65617 请求体为空属正常。

`CarlifeFeatureConfigProto.proto`：`key=1(required string) value=2(required int32)`。

`CarlifeWirlessTargetProto.proto`：`wifiDeviceName=1 targetInfo=2 scanRecord=3 p2pNetInfo=4`，
注释里给出盒子 P2P 组参数格式 `"box, 88888888, 5745, 2"`（名字, 密码, 频率, 频段）。

## I. USB 直连：AOA 配件模式（全细节）

- **真实车机走 AOA（Android Open Accessory），不是 USB 网络模式。**
  证据：① `UsbProbe` 报 `ACCESSORY`；② `hdc shell ifconfig -a` 全量网卡里
  **没有任何 usb0/rndis0/eth1**（只有 wlan0 + rmnet* + ancowlan0）。
- 鸿蒙 AOA API 齐备（`@ohos.usbManager`，@since 14，**无需额外权限声明**）：
  `getAccessoryList / hasAccessoryRight / requestAccessoryRight / openAccessory → USBAccessoryHandle.accessoryFd
  / closeAccessory`；fd 用 `@kit.CoreFileKit` 的 `fileIo.read/write` 收发。
- **★ 最大未知：AOA 只有一条字节流，7 个逻辑通道的复用格式未知。**
  TCP 侧帧头**不含通道号**（通道由 7 个端口隐含），所以 USB 侧必有额外封装 ——
  **写传输层前必须实测拿到**。`refs/carlife_pc_tool` 帮不上（它 USB 走 `adb forward`，非 AOA）。
- ⚠️ 手机自带 CarLife 支持（「百度CarLife+」元服务 + `com.huawei.hmos.cardistributedassist`；
  hilog 见 uid 5557 注册蓝牙 SDP `carlife`）**可能抢先占用 AOA 配件**，试连报 14401003 要先关掉它。
- 车机端 APK 另有 `BLUETOOTH_AUTO_PAIR` / `CONFIG_TARGET_BLUETOOTH_NAME` /
  `VALUE_INT_BLUETOOTH_AUTO_PAIR` / `BLUETOOTH_INTERNAL_UI` /
  `InstantConnectionSetup multiple bluetooth socket!!!` / `BluetoothCommunicator onReceiveMessage/onSendMessage`
  / `BluetoothDeviceDiscover`；密码常量 `12345678` 亦在其中。

## J. USB 调试连接：鸿蒙手机不需要装驱动

- **报「无法识别的 USB 设备(设备描述符请求失败)」≠ 缺驱动。**
  判据：设备实例 ID 是 `USB\VID_0000&PID_0002\...`（Windows **连描述符都没读到**），
  `ProblemCode = 43`（CM_PROB_FAILED_POST_START）。缺驱动会读到真实 VID/PID 再报 28。
- DevEco Studio 全目录**无任何 `.inf`/`.cat`/winusb 驱动包**（已 find 验证），系统只有自带 `winusb.inf`；
  CSDN 教程也没有「装驱动」这一步 → **装驱动是无效动作。**
- **失败时该查**：① 换**数据线**（最常见，很多线是纯充电线）；② 换 USB 口；③ 手机侧 USB 连接模式。
- **同口对照法**：比 `DEVPKEY_Device_LocationInfo`（如 `Port_#0005.Hub_#0001`）。
  本机该口曾成功枚举 `HUnitBox`（`USB\VID_18D1&PID_4EE7`，走 `winusb.inf` 成「ADB 设备」）。
  ⚠️ **`HUnitBox` 是 PC 上 ADB 设备的产品串，不是车联盒子** —— 车联盒子是 `Box_259E`。
- **hdc 走 WiFi 时**：P2P 连接动作会让手机掉出家里 WiFi → hdc 断，别把 WiFi 调试当唯一通道。

## K. 其他环境事实

- 车机端 APK 曾跑在本机 **Hyper-V 虚拟机**（`vEthernet (MyApps vSwitch)`，172.29.224.x，
  VM MAC `00-15-5d-*`），经 NAT 出网，源 IP 显示为宿主机 `192.168.31.65`
  —— **宿主机 netstat 看不到它的连接，别被误导**。
- 车机端 APK 路径：`C:\Users\ZM\Documents\xwechat_files\zi---min_93f7\msg\file\2026-05\CarLife4.0车机端.apk`；
  官方手机端：`C:\Users\dev\Desktop\bdc_16031.apk`。
- 网页查证：盒子必须**在车机启动完成之后**再插上（CarLife 协议在开机后才加载），否则车机识别不到。

## L. 输入注入（模拟触控）的权限现实

### 官方注入 API：`CONTROL_DEVICE` —— 普通应用拿不到
- `@kit.InputKit` → `inputEventClient.createKeyboardController() / createMouseController() /
  createTouchController()`，`@since 26.0.0`，`@stagemodelonly`，**非 `@systemapi`**。
- `TouchController`：`touchDown/touchMove/touchUp`，`TouchPoint`，最多 10 个点，须同 `displayId`，
  序列必须 down → (move)* → up。
- **权限 `ohos.permission.CONTROL_DEVICE`**（不是 `INJECT_INPUT_EVENT`，那个名字不存在）：
  - `grantMode = manual_settings`（全机 881 条权限里只有 4 条是这个值）
    → 声明后**装机即失败** `code:9568289`，**整包装不上**；且缺 `reason`/`usedScene` 时构建期报 `00303218`
  - `deviceTypes = ["2in1"]` → **手机上调用回 `801 Capability not supported`**
  - `availableLevel = system_basic`，`availableType = NORMAL`（不在 ACL 白名单，也不承诺可得）
  - 授权四口全不通：`requestPermissionsFromUser` 静默返回 `authResults=2 / dialogShown=false`；
    `requestPermissionOnSetting` 抛 `12100014`；`openPermissionOnSetting` 抛 `12100001`；
    `getSelfPermissionStatus` 回 `INVALID(2)`
  - ⚠️ `canIUse('...InputSimulator')` 在手机上也返回 **true**，不可作判据
  - 依据：官方文档「仅在 PC/2in1 设备中可正常调用」+ `ost.51cto.com/posts/59151` 双机实测

### 可用替代：无障碍扩展（AccessibilityKit）
- `AccessibilityExtensionAbility`（未弃用）+ `AccessibilityExtensionContext.injectGestureSync(GesturePath)`
  （`@since 10`，无 `@permission` 标签；⚠️ 标了 `@deprecated since 12` 且无 `@useinstead`，**需实测**）。
- `GesturePath{ durationTime: ms, points: GesturePoint[] }`，`GesturePoint{ positionX, positionY }`（px）。
- 授权：**用户在「设置 → 无障碍」手动开启服务**，不需要 root / 系统签名。
- 配置：`extensionAbilities[]` 里 `"type": "accessibility"` + metadata
  `"ohos.accessibleability" → "$profile:accessibility_config"`；
  `accessibility_config.json` 里 **`accessibilityCapabilities: ["retrieve", "gesture"]`**。
  ★ 2026-10-13 实测**证伪**了此前记的 `accessibilityExtensionTypes` —— 用
  `accessibility.getAccessibilityExtensionListSync('all','install')` 读到本应用返回
  `capabilities=[retrieve,gesture]`，说明键名就是 `accessibilityCapabilities`。
  合法取值：`retrieve | touchGuide | keyEventObserver | zoom | gesture`。
- AEA 在**独立进程**，主 Ability 需跨进程把触控坐标送过去（commonEvent / socket / rpc）。
- 兜底：`hdc shell uitest uiInput click x y`（设备侧，**需 PC 常连**，车里不适用）。

## M. CarLife 的触控到底走什么通道（2026-10-13 考证）

**结论：官方 CarLife 不走无障碍通道。** 别拿「CarLife 能反控」当「无障碍可行」的旁证 —— 两者不是一回事。

| 场景 | 车机画面上是什么 | 车机回传坐标要落到哪 | 需要特权吗 | CarLife 实际用什么 |
|---|---|---|---|---|
| **经典模式**（导航/音乐/电话） | CarLife **自己渲染的 UI** | **它自己的 View 树** | **不需要** | 应用内 `dispatchTouchEvent` |
| **超级投屏**（投第三方 App） | 别人的 App | **别人的进程** | 需要 | **ADB**（`adb tcpip 5555`） |

**硬证据**：官方「解锁超级投屏」页（`carlife.baidu.com/static/carlifemis/unlock/index.html`）
要求 PC + USB 线 + ADB 授权；其解锁工具 `.bat`
（`car-life.cdn.bcebos.com/release/supercast/assets/CarLife超级投屏解锁工具.bat`）
核心只有一句 `adb -s <serial> tcpip 5555` —— 把手机 adbd 开成 TCP 监听，
让 CarLife 自己连本机 ADB 拿 **shell 权限**。**跟无障碍无关。**

**推论（未直接验证，但有实测旁证）**：CarLife 手机端 APK 未声明 `AccessibilityService`。
APK 各渠道直链都取不到（应用宝 `apk_url` 置空、镜像站被墙），**这点仍属推断**；
但**大哥实测确认：CarLife 装好后从未提示开启无障碍** —— 直接佐证「它不依赖无障碍」。
（若将来拿到 APK，用 `aapt dump xmltree ... AndroidManifest.xml | grep -i accessibility` 一击定案。）

**对我们的含义**：CarHi 镜像**整机屏幕** → 车机上点到的是任意第三方 App → 必须跨进程注入
→ 鸿蒙非 root 只有无障碍一条路。**CarLife 不需要无障碍，是因为它不镜像整机。**

**强佐证**：本机 `[无障碍自检]` 查出华为自家**车机互联** `com.huawei.hmos.cardistributedassist/
AccessibilityExtAbility` 声明了 `capabilities=[retrieve,keyEventObserver,gesture]` ——
它同样做镜像，同样走无障碍。**同一个逻辑，CarHi 的选择与华为一致。**

## N. 推流验证速查（2026-10-13 实测定型）

### 一条命令跑完整模拟
```bash
cd <项目根> && python tools/mock_hu.py --host <真机IP> --duration 30 --hb-hz 5 \
                                            --width 1920 --height 720 --fps 30
```
- `--strict` 有 FAIL 时退出码非 0（可接 CI / 脚本判定）。
- **真机屏幕（车机模式）实际是 `1920×720` 横屏** —— 用它跑才贴近真实。
- 预期 **30 项全过**；核心是 `VIDEO(8240) 收到 131073 视频帧` + H.264 Annex-B 起始码。

### ★ 测「默认值」的技巧：下发 0 参数
`onHuVideoEncoderInit()` 只在 `enc.width > 0` 时才覆盖默认值。
所以 `--width 0 --height 0 --fps 0` 会让**默认值保留**，从 `65544` 回包里**直接观测到默认值**。
（正常下发会被覆盖，外部看不到默认值 —— 想验默认值必须用这个测法。）

### 0 帧的两大常见原因（先查这两个）
1. **录屏授权态未就绪**（App 刚重启时最常见）。同一分钟「0 帧 → 152 帧」常只是时序问题。
   设备侧日志找 `[授权] 即将弹出系统录屏授权框`。
2. **视频通道未连**（`isVideoReady == false` 时帧被直接丢弃，见 `CarLifeEngine.onEncodedFrame`）。

### 设备侧日志抓取（两个坑）
```bash
# 1) 起捕获（会自杀、无残留）
hdc -t <serial> shell "nohup timeout 60 hilog -T CarHi,CarHiA11y > /data/local/tmp/x.log 2>&1 &"
# 2) 取回 —— ★ 必须 MSYS_NO_PATHCONV=1，否则 Git Bash 把远程绝对路径当相对路径拼错
cd <目标目录> && MSYS_NO_PATHCONV=1 hdc -t <serial> file recv /data/local/tmp/x.log x.log
# 3) 清理遗留 —— ★ 必须按 pid kill -9（pkill -f 只杀 timeout 父、留孤儿）
hdc -t <serial> shell "ps -ef | grep hilog | grep -v grep"   # 看清 pid 再 kill
```
**日志 tag 是 `CarHi`**（`A00001/com.carhi.carlifephone/CarHi`），无障碍扩展是 `CarHiA11y`。

### 关键日志行（判断链路走到哪一步）
```
[视频] 车机期望编码参数: 1920x720 @ 30fps
[编码] 启动: 1920x720@30fps, 码率 4147kbps, Profile=Baseline, 低延迟开启
[编码] 管线就绪，编码器实际输出 1920x720     ← native 层回读的真实值（最硬）
[触控] ← TOUCH_ACTION action=0 x=320 y=240   ← TOUCH(9340) 入站解析工作
[保活] 65563 已发送 ×N（失败 0）
```

## O. 录屏通路（**代码还在、是活的**）+ 「切应用掉线」排查

⚠️ **2026-10-16 修正**：`cpp/screen_encoder.cpp` / `screen_encoder.h` / `ets/core/ScreenCaptureSource.ets`
**都还在**，且就是**当前投屏的实际实现**（`OH_AVScreenCapture_StartScreenCaptureWithSurface`）。
此前记忆里"录屏已删、全仓 0 处调用"是**错的**。

### ★★★ 「投屏时切应用掉线」= 已排除 App 侧（2026-10-16 实测定型）

**结论：切后台不会掉线。真因是「外部 peer 反复重连，把旧连接顶掉」。**

#### 推翻了什么

本节曾有两个**错误结论**，都已作废：
1. 「AUDIO_RECORDING 名实不符 → 长时任务被挂起 → 切后台冻结」——**错**。
   建立在"CarHi 采集侧不采音频"的错误前提上（旧代码 `micCapInfo.audioSampleRate = 48000`，
   按 `native_avscreen_capture.h` 语义「rate 与 channels **都为 0** 才不采集」⇒ 其实开了麦克风）。
2. 「`[投屏] 采集已停止` = 采集被主动停掉」——**因果读反了**。它只是**连接断开的后果**。

#### 三条铁证

| # | 证据 | 原始日志 |
|---|---|---|
| **A** | **切后台 23 秒零异常** | `12:06:08.336 onBackground` → `12:06:31.756 onForeground`；期间车机视频心跳 ×480→×580 **连续**、`65563` 保活 ×50/×60 **连续**、**0 次 `通道 N 已断开`、0 次 `continuousTaskSuspend`**；`★[保活] 长时任务重新激活 id=395` 只在切回前台时出现 |
| **B** | **前台也照样断** | `12:06:49.606 通道 1 已断开` 时 App **已在前台**（12:06:31 起）⇒ 与前后台无关 |
| **C** | **谁断的：新连接顶掉旧连接** | `NETSTACK: Server accept new client, fd=73 clientfd=83` → `js invoke TcpConnectionClose` → `通道 1 已断开` |

铁证 C 的代码依据 —— `transport/ChannelServer.ets:118 handleConnection()` **有意为之**：
```ts
// 单通道只保留一个活跃连接（CarLife 语义：一条通道一个连接）
if (this.conn !== null) { this.closeConnection(); }
```

#### 因果方向（重要，别再读反）

```
外部 peer 连上来（Server accept new client）
  → ChannelServer 主动 closeConnection() 踢掉旧连接
  → 通道 1..7 全部「已断开」
  → CarLifeEngine 检测到断连 → engine.stop()
  → stopStreaming() → ScreenCaptureSource.stop() →「[投屏] 采集已停止」
  → native OH_AVScreenCapture_StopScreenCapture
```
**采集停止 = 后果。** 之前把它当成"采集被主动停"是反向归因。

#### 外部 peer 是谁

- 连来自 `192.168.0.131` —— **就是宿主机自己**。
- 自称 `brand=samsung, model=SM-N9860, display=TQ2A.230505.002 release-keys`、
  请求 `1280x720@60fps`、`HU_INFO` **347 字节**。
- ⇒ **与仓库 `tools/mock_hu.py` 不是同一个脚本**（后者 HU_INFO 只有 **49 字节**、
  默认 **30fps**，且真机解析出来 `brand=` 是空的）。
- 它按**不规则间隔**（实测 17s / 27s / 80s）反复重连，每次重连都触发一次上述链条。

#### ★ 定位手法（比猜代码快得多）

```bash
hdc -t <ip:port> shell "cat /proc/net/tcp"
```
把 local port 从十六进制转回来，取 `state=01`（ESTABLISHED）那几行，即可读出
**对端 IP**：
`7240=0x1C48`（CMD）/ `8240=0x2030`（VIDEO）/ `9240=0x2418`（AUDIO）/ `9241=0x2419`（TTS）/
`9242=0x241A`（VR）/ `9340=0x247C`（TOUCH）/ `9440=0x24E0`（DATA）。

⚠️ **宿主机上 `netstat -ano` 在本沙箱里看不到这些连接**（连 hdc 自己的连接都查不到），
**别用它下结论**；以手机侧 `/proc/net/tcp` 为准。

#### 保留的改动（都有效，勿回退）

| 改动 | 文件 | 作用 |
|---|---|---|
| `micCapInfo` 置 0 + `SetMicrophoneEnabled(false)` | `cpp/screen_encoder.cpp` | 消除"注释说不用麦、实现却开麦"的矛盾（头文件明说后台不允许激活麦克风） |
| 注册 `SetDataCallback` 消费内录音频（`AUDIO_INNER` 计数落日志） | `cpp/screen_encoder.cpp` | 名实相符；顺带可接 CarLife AUDIO(9240) |
| 监听 `continuousTaskSuspend/Active/Cancel` + `getAllContinuousTasks(ctx,true)` | `ets/core/BackgroundKeeper.ets` | **诊断**：切回前台即可见"是否被挂起、原因"，不依赖 hdc |
| 设置页「保活」诊断行 | `ets/pages/Index.ets` | 显示 `BackgroundKeeper.diagText` |
| **移除 LOCATION 长时任务** | `ets/core/BackgroundKeeper.ets` | 全仓无定位业务，`SYSTEM_SUSPEND_LOCATION_NOT_USED=8` 会被挂起 |

**判读口径**：切后台再回前台看「保活」行 ——
`✔ 未发生挂起` ⇒ 掉线与长时任务无关（**本次实测即此结果**）。

#### ★ 附带发现（待修）

切回前台时观察到一次**自动**的 `stopAppCast()` → `startAppCast()` 往返：
```
12:06:33.472 [投屏] 采集已停止
12:06:33.472 [画面源] 正在切换画面源（停旧管线 → 按原参数重启）…
12:06:33.473 [投屏] 已停止采集，画面源切回自绘
12:06:34.425 ★ 应用投屏已启动｜第 8 次尝试
```
会白重建一次采集管线（编码器 stop→start）。**`stopAppCast()` 全仓只有按钮 `onClick`
一个调用点**（`Index.ets:802`），所以"自动往返"的触发源尚未找到 —— 下次可从
"切回前台是否重建页面 / `aboutToAppear` 是否重跑"入手。

### 历史踩坑（维护/恢复时仍会遇到）
以下三条是当年在录屏方案上踩出来的：

1. **采集策略必须在 `StartScreenCapture*` 之前调**（`ApplyCaptureStrategyLocked()`）：
   `StrategyForPickerPopUp(false)`（★核心，消除录屏授权弹窗）、
   `StrategyForKeepCaptureDuringCall(true)`、`StrategyForCanvasFollowRotation(true)`。
2. **采集状态码 5/6/7**（MIC_UNAVAILABLE / MUTED / UNMUTED）本项目不走麦克风，
   **必须忽略** —— 曾一律当「中断」重启采集 → 每 2 秒自杀式重建管线。**8/9**（PRIVATE_SCENE）同样忽略。
3. **`RestartCapture()` 必须有冷却**（当年用 `kRestartCooldownMs = 3000`），否则抖动期疯狂重建。

## P. CarWith 导航卡版式原文（2026-10-15 已实现，出自 `refs/carwith_decoded` + `refs/carwith_src`）

来源 APK：`com.miui.carlink404.apk`。**`refs/` 被 gitignore，换机需重新解包。**

### 进度条 = 整卡背景（最标志性的特征）
`com/carwith/launcher/card/LinearProgressView.java` 的 `onDraw()` 只有两行：
```java
canvas.drawRect(0, 0, getWidth(), getHeight(), bgPaint);            // 底色铺满
canvas.drawRect(0, 0, getWidth() * progress / 100f, getHeight(), fillPaint);  // 进度从左往右
```
300ms AccelerateDecelerate 动画，progress 0~100 夹取。
**不是**「卡片下面一条细进度线」——是整个卡片本身被填充。

### 布局与字号（`nav_progress_view_1a.xml` / `NavProgressView1A.java`）
- `progress_view` = match_parent（整卡）；`icon_view` = `layout_constraintWidth_percent="0.24"`、
  1:1、垂直居中；`cross_icon_view`（路口放大图）默认隐藏。
- 文本：`tv_distance` 30sp bold 黑、`tv_distance_unit` 16sp bold、`tv_action` 20sp bold 灰、
  `tv_address` 16dp 灰。
- ★ `NavProgressView1A.g(int width)` 会按**卡宽**重算字号 —— 本项目照抄的比例：
  距离 `0.12f*w`、单位 `0.07f*w`、动作 `0.071f*w`、路名 `0.06f*w`。

### 色值（`res/values/colors.xml`）
`nav_progress_color #d8e6ff`（日间）/ `nav_progress_color_night #cc9cc3cc`、
`transparent_20 #33ffffff`、`text_color_distance #000000`、`tel_light_grey #99ffffff`、
`media_card_music_background #6dfbfbfb`、`phone_car_docker_line_color #33000000`、
`driving_mode_docker_default_height 65.0dp`。

### 驾驶模式整页（`layout_driving_mode_main.xml`）
顶部地图卡（16dp 边距 / 16dp 圆角 / `TextureView`）→ 112dp 音乐卡 → 65dp docker 栏
（42/46/40dp 图标，1×32dp 分隔线，24dp 间距）。`card_fastnav.xml` 家/公司两行 weight 43/43，
粗体 18 + 灰 16，1dp 分隔线，48dp 图标。

### 参照模板（`design/nav-hmi/RESEARCH.md`，Google Android Auto 导航模板）
**全屏底图 + 浮层卡**（路线卡、ETA 卡）+ 顶部动作条 + 右下 FAB —— **不是左右分栏**。
1920×720 是 CarPlay 官方分辨率之一；深色主题强制；3 秒法则；对比度优先于描边。

### 本项目实现落点（`hmi_renderer.cpp`）
`DrawNaviPage` = 全屏 `DrawMap` 铺底 + 三个浮层：`DrawNaviGuideCard`（左上 460×196）、
`DrawNaviNextBar`（左下）、`DrawNaviFab`（右下十字准星）。
字段：`HmiNaviInfo.progress`（0-100）→ `napi_init.cpp` `GetIntProp("progress")`
→ ArkTS `NativeHmiSource.setNavi(...)` 第 7 个参数 → `Index.ets` `@State navProgress`。

## Q. 高德导航 SDK 接入（2026-10-15 实测通过，照抄即可）

1. 依赖（**ohpm 公开仓库**，真包名）：`"@amap/amap_lbs_navi": "11.2.1"`
   —— ⚠️ 还要**显式**装子依赖 `@amap/amap_lbs_common@11.2.1` + `@amap/amap_lbs_location@11.2.1`。
   **ohpm 路径**：`DevEco Studio/tools/ohpm/bin/ohpm.bat`（不在 sdk/toolchains 下）。
2. ★ **`useNormalizedOHMUrl: true`**（`harmony/build-profile.json5` 的
   `products[0].buildOption.strictMode`）—— 高德是 **Bytecode HAR**，不开直接构建失败 `00306046`。
3. ★ **隐私合规必须先调**（否则抛异常/崩溃）：
   ```ts
   NaviSetting.updatePrivacyShow(AMapPrivacyShowStatus.DidShow, AMapPrivacyInfoStatus.DidContain, ctx);
   NaviSetting.updatePrivacyAgree(AMapPrivacyAgreeStatus.DidAgree, ctx);
   ```
   隐私枚举从 **`@amap/amap_lbs_common`** 导；`NaviSetting` 从 navi 包导。
   顺序铁律：**隐私合规 → `getAMapNaviInstance` → `addAMapNaviListener`**。
4. `AMapNaviFactory.getAMapNaviInstance(getApplicationContext(), key)`，
   context **必须**是 ApplicationContext。成功标志：`onInitNaviSuccess()` 回调。
5. 权限：`LOCATION` + `APPROXIMATELY_LOCATION`。
6. ⚠️ SDK 的 native so **只有 arm64-v8a**；我们 abiFilters 含 x86_64（模拟器会缺库）。
7. HAP 体积从 ~20MB → **132MB**（地图引擎 + 6 个 so），属正常。

### 数据能力（`INaviInfo`，源码级核实）
**能拿结构化数据**：`mCurRoadName` / `mNextRoadName` / `mIcon` / `mSegRemainDis` /
`mRouteRemainDis` / `mRouteRemainTime` / `currentSpeed` /
**`routeRemainLightCount`（前方红绿灯数量）** / `iconBitmap`（转向图标位图）/
`crossIconBitmap`（路口放大图位图）。
**拿不到结构化数据**：红绿灯**倒计时/灯色** —— `setTrafficLightsVisible()` 只有显隐开关，
`onShowTrafficLight()` 是**无参**事件。要看倒计时**必须嵌 `AMapNaviView`** 渲染。

### 代码落点
- `core/AmapNaviBridge.ets` —— 数据桥（取数据→填快照，不画面）
- `core/NaviInfoProbe.ets` —— 探针（含高德初始化 + Car Kit 探针）
- Key 常量 `AMAP_KEY` 在 NaviInfoProbe.ets；appId 由 `EntryAbility.logAppId()` 打印

## R. Car Kit 能力边界与「四件套」（2026-10-16 修正）

### ★ 四件套 —— 缺一件整条链路就废
| 要件 | 之前 | 现在 |
|---|---|---|
| 编译模式 **release** | ❌ 一直用 debug 包（`build.sh` 默认 `MODE=debug`） | ✅ `bash tools/build.sh release` |
| 权限 `ACCESS_SERVICE_NAVIGATION_INFO` | ✅ | ✅ |
| 权限 `ACCESS_CAR_DISTRIBUTED_ENGINE` | ✅ | ✅ |
| skills `action.navigation.infoservice` | ❌ 缺 | ✅ 已加 |
| metadata `carHopCapability`/`hiCarCapability` | ❌ 缺 | ✅ `carHopCapability: insideCarNavi` |

- 博客原文：**「metadata 的 carHopCapability / hiCarCapability 至少声明一个，否则车机识别不到应用」**
- **怎么判包是 debug 还是 release**：HAP 内 `module.json` 的 **`app.buildMode` / `app.debug`**。
  ⚠️ **`app.apiReleaseType` 两边都是 `Release`，区分不出来**。
- 运行时判据：`bundleManager.getBundleInfoForSelfSync(GET_BUNDLE_INFO_WITH_APPLICATION)`
  → `appInfo.debug`。`EntryAbility.logBuildMode()` 启动即打，日志 tag `CarHi`。
- **教训**：`801 Capability not supported` 在 debug 包下也会出现，
  **不能拿 debug 包的负结果给整个能力判死**。

### 正确认识：Car Kit 给生态开放的是「流转」+「状态感知」，不是「取画面」
| 能力 | 能否用 | 依据 |
|---|---|---|
| `navigationInfoMgr` 上报（updateNavigationStatus / updateNavigationMetadata） | ✅ 可用（已实测） | 权限 `ACCESS_SERVICE_NAVIGATION_INFO` = normal + system_grant |
| `navigationInfoMgr` **读取**导航数据 | ❌ **不存在** | `NavigationController` 全部方法只有 4 个：2×update + register/unregister |
| `smartMobilityCommon` **主动查询**（连接状态 / 事件） | ✅ **可用（2026-10-16 实测）** | `getSmartMobilityStatus` / `getSmartMobilityEvent`；权限 `ACCESS_CAR_DISTRIBUTED_ENGINE` |
| 读「导航数据」（转向/距离/路名/车道线） | ❌ 代码做不到 | 见下 |

#### ★★ 2026-10-16 真机实测（release 包）—— 把「能读到什么」钉死
```
11:02:11 === Car Kit 导航信息探针开始（buildMode=release）===
11:02:11 ★ 第1步 getNavigationController() 成功，ctrl=非空
11:02:11 ★ 第2步 registerSystemNavigationListener 注册成功
11:02:11 ★ [读] getSmartMobilityStatus(HICAR)          status=0 type=0 DEVICE_TYPE= DISPLAY_ID= IS_PHONE_DESKTOP=false
11:02:11 ★ [读] getSmartMobilityStatus(SUPER_LAUNCHER)  status=0 type=1 DEVICE_TYPE= DISPLAY_ID= IS_PHONE_DESKTOP=undefined
11:02:11 ★ [读] getSmartMobilityStatus(CAR_HOP)         status=0 type=2 DEVICE_TYPE= DISPLAY_ID= IS_PHONE_DESKTOP=undefined
11:02:11 ★ [读] getSmartMobilityEvent(CAR_HOP, CAR_HOP_EVENT/HICAR_EVENT/SUPER_LAUNCHER_EVENT)  data={}
```
- **读取接口可调、不抛异常** ✅；但三个 type 全是 `status=0`（**IDLE**）、`DISPLAY_ID` 空、event `data={}`
  → 因为没有 HiCar / 超级桌面 / 流转在跑。
- **它读的是「连接状态 + 虚拟屏归属」，不是导航数据。** 导航数据（转向/距离/路名）**只有 update，没有 get**。
- **另一条实测**：高德在导航中、CarHi 已注册 listener 的 25 秒内，**零 `onQueryNavigationInfo` 回调**
  → 没有车机角色时，系统不会来查。

#### ★★★ 2026-10-16 华为官方智能客服最终确认（权威定案，三方一致）
大哥手动向华为开发者智能客服提问，客服明确回答（原文摘录）：
- 「NavigationController 接口**一共只提供 4 个方法**……**不存在** `getNavigationInfo` 之类可以主动
  "读取/获取"导航数据的接口」
- 「模块级函数 `getNavigationController()` 虽然名字带 get，但它获取的是 **NavigationController
  控制器实例本身**，而不是导航数据」
- 「该模块的定位是 **地图导航应用向系统上报导航信息**……接口设计为"**写入 + 被动响应查询**"模式」
- 「`onQueryNavigationInfo`……是"**系统查询、应用应答**"的被动模式，**并非应用侧的主动拉取接口**」
- 「如果您的场景是作为导航数据的**消费方**（例如仪表、AR-HUD 应用）想主动拉取转向、剩余距离等信息，
  navigationInfoMgr 模块**并不提供此类接口** —— 数据由地图应用上报后经系统分发」

⇒ **SDK 源码分析 + 真机实测 + 官方客服 三方一致 → 「Car Kit 取导航数据」正式判死，不必再试。**

#### ★★★ 客服第二答（问「官方推荐路径」）—— 补了根本原因 + 澄清一个误区
**结论：Car Kit 无法覆盖 CarLife 车机场景。** Car Kit 只面向两类车机：**鸿蒙智行车机**（含仪表/HUD）
和 **HiCar 认证车机**；百度 CarLife 属百度主导协议，**不在华为官方对接范围内，没有推荐路径**。

**两层硬性限制**：
1. **数据获取层**：「HarmonyOS 的**应用沙箱机制** —— 第三方应用**无法读取其他应用的运行时数据**，
   "读取高德 App 正在导航的数据"这条路**在系统层面就被封死了**」← **比"接口没开放"更根本**
2. **传输通道层**：Car Kit 的流转通道只连鸿蒙智行/HiCar 车机，**没有接口能推到 CarLife 车机**

**★ 客服澄清的关键误区（必须纳入产品决策）**：
> 「集成高德/百度开放平台 SDK **并不能"读取高德地图 App 的导航数据"**。地图 SDK 提供的是
> **让您自己的应用发起导航**的能力……数据属于**您应用自己发起的导航会话**。
> 所以实际含义是：**用户必须在您的应用里发起导航**，您的应用才能拿到实时导航数据。」

**客服给的三条路 + 对 CarHi 的对照**：
| 客服说的路 | 对 CarHi 是否适用 |
|---|---|
| ① 车机支持 HiCar → 走官方 | ❌ 大哥车机跑 CarLife，未认证 HiCar |
| ② 接入 CarLife 协议（需百度授权） | ✅ **CarHi 已自实现 CarLife 协议（TCP 7240/8240…），无需百度授权** |
| ③ 自建通道（蓝牙/WiFi 私有协议）**+ 车机侧装接收端** | ✅ **CarHi 走的就是这条，但不需要"车机侧装接收端"** —— 用的是**车机自带的 CarLife App** |

**⇒ CarHi 的路线客服没覆盖到**：既不是"官方 Car Kit 路径"，也不是"需要车机装东西的私有协议"，
而是 **「复用 CarLife 协议 + 车机自带 CarLife 端」** —— 这是 CarHi 相对客服所述方案的关键优势。

#### ★ 关键：录屏（应用投屏）**绕开**沙箱 —— CarHi 的两条可行路线
客服说"第三方读不到别的应用的数据" —— **对**。但 **`OH_AVScreenCapture` 录屏不需要"读数据"，
只需要"看屏幕"**，**沙箱不拦**。

- **A 自绘导航**：CarHi 内嵌高德 SDK **自己发起导航** → `HmiRenderer` 画导航卡 → CarLife 协议推流
  （**用户操作在 CarHi 内**）。数据干净、界面可控。← 已打通（Q 节）
- **B 应用投屏**：CarHi 录屏（**含高德 App 画面**）→ 编码 → CarLife 协议推流
  （**用户操作在高德 App 内**）。画面原样搬运。← 已打通（S 节）

⇒ **两条路都不依赖 Car Kit，也不受沙箱限制。** 大哥最初要的"搬运"= **路线 B**，已具备。

#### `SmartMobilityInfo.data` 的真实字段（官方《主动获取HiCar的连接状态》）
`DEVICE_TYPE`（设备类型）/ `DISPLAY_ID`（**业务所在的虚拟屏 ID**）/ `IS_PHONE_DESKTOP`（是否在 HiCar 上显示手机桌面）。
**拿车机屏幕尺寸的路子**：`getSmartMobilityStatus(SUPER_LAUNCHER).data['DISPLAY_ID']`
→ `@ohos.display.getDisplayById(id)` → width/height。**前提：HiCar/超桌面已连接**（大哥的 CarLife 车机不在这条链路）。

#### 导航数据的**唯一**去向（官方论坛原文）
> 「**系统业务向 Car Kit 订阅导航数据变化：当生态应用导航数据发生变化时需通知到 Car Kit**」

⇒ **生态应用（高德）= 发布方；系统/车机 = 订阅方。第三方应用（CarHi）不在任何一端。**
（`bm dump -n com.amap.hmapp` 实证高德才是数据源：`naviInfoServiceCapability: naviOperation` + `action.navigation.infoservice`。）

### 铁律：`superLauncherCapability` 不存在
- 官方《开发准备·配置能力》原文：**「metadata 的 name 可选值：carHopCapability、hiCarCapability」—— 只有两个**
- "超级桌面" 只是 `smartMobilityType.SUPER_LAUNCHER` **枚举值**，不是 metadata 字段
- ⇒ 没有「声明我支持超级桌面」的入口。靠华为侧把包名纳入目录/白名单（生态运营流程，代码解决不了）。
- 大哥的安卓老车机根本没有超级桌面 → 对当前目标本来也无效。

### `smartMobilityCommon` 的 API 边界（源码级）
- `SmartMobilityInfo = { status, type, data: Record<string,Object> }`，
  `data` 官方标注"由业务方自定义" → **没有文档化的 screenWidth/Height**。
- `SmartMobilityType` = HICAR(0)/SUPER_LAUNCHER(1)/CAR_HOP(2)；
  `SmartMobilityStatus` = IDLE(0)/RUNNING(1)。
- HiCar 侧的 `getScreenWidth`（`com.huawei.hicarsdk.CarConfig`）是**安卓车机厂商 SDK**，
  鸿蒙手机应用用不了。

### ★ 待办：用 `smartMobilityStatus` 防 HiCar 抢通道（最有价值）
`getSmartMobilityStatus(HICAR)` / `on('smartMobilityStatus')` 权限已具备。
`status == RUNNING` ⇒ HiCar 已占住投屏通道 → **不要启动录屏**，UI 提示
"HiCar 正在使用车机，请先断开 HiCar"。直接治"一投屏就卡在切换"那类现象。

### 其它路线判死依据（2026-10-15）
| 路线 | 结论 | 证据 |
|---|---|---|
| 系统级屏幕镜像（CarWith / CarLife 手机端那套） | ❌ 判死 | 需 `CAPTURE_VIDEO_OUTPUT` 等 **system\|privileged** 权限（官方 CarLife 手机端 APK manifest 实证），普通应用拿不到 |
| DV Engine（设备虚拟化） | ❌ 双死结 | 设备侧要 `android:sharedUserId="android.uid.system"`（系统签名）+ 华为南向适配；手机侧仅华为 EMUI 10.1+；**「成为合作伙伴」原文「仅适用于企业账号，不适用于个人账号」** |
| HiCar 车机侧 SDK（`hicarsdk.aar`） | ❌ | 需企业主体 + 华为合作伙伴计划 + 送测认证 |
| AVSession Kit / CastEngine / ShareEngine | ❌ 无关 | 本仓零引用；AVSession 管播控不传画面 |

## S. 界面 / 渲染器细节（`hmi_renderer.cpp` / `pages/Index.ets`）

- **★ 手机屏幕 ≠ 车机画面**。2026-10-15 大哥确认「手机端不需要导航页面，只显示设置内容」
  → 手机侧 HMI 预览（`SideRail`/`HomePage`/`MapOnlyPage`）**已从 build() 摘除**
  （builder 仍在文件里未调用），`build()` 就是 `Stack { SettingsPage() }`；
  车机页面切换入口在设置页顶部「车机画面 [首页][导航]」，`@State page` 默认 **1（导航）**。
  `startFallbackPush()` 截 `id('hmi_root')` 的兜底仍在，仅 `frameSource.isFallback == true` 时跑。
- **★ 静态字段必须镜像成 `@State` 才会刷新**：`BackgroundKeeper.isActive`、`CaptureGate.label`
  是普通静态字段，`build()` 里直接读只取首帧值。现由 300ms `tickTimer` **变化时才同步**。
- **★ 「已在 … 端口监听」曾是无条件假通过**：`CarLifeChannelServer.start()` 逐端口 try/catch，
  绑失败**不抛异常**。现按真实结果输出（`listenResults`/`listeningCount`）。
  **改动监听相关代码后，务必用 `/proc/net/tcp` 核对真的 LISTEN。**
- **★ 渲染器跨实例共享文件级静态资源 → 必须加锁**：`g_fill` / `g_pen` / `g_textSlots` 是
  文件级静态。`RunSelfCheck()` 会 `ResetTextCache()`（销毁在线线程正在用的 Typography）并以
  `DestroyBackend()` 收尾（销毁 `g_fill`/`g_pen`）→ 在线推流中点「离线自检」= **use-after-free**。
  已加 `std::mutex g_drawMutex`：`RunSelfCheck` 全程持有，`RenderOnce` 两条分支在 `DrawFrame`
  外加锁。**新增任何动这些静态资源的函数，都要先拿这把锁。**
- **★ `DrawRail(c, page)` 的激活态必须跟页走**：曾把 rail 高亮硬编码成 HOME →
  导航页上首页图标亮着。现由 `homeActive`/`naviActive` 驱动。
- **★ CarWith 导航卡版式**（2026-10-15 实现，`DrawNaviGuideCard`）→ 原文与色值见 **P 节**。
- `CarLifeRuntime.logs` 上限 **300 条**，排查时注意会被裁剪。布局细节 → **E 节**。
- **★ ArkUI 状态管理禁令：`AppStorage.setOrCreate` 不接受函数**（2026-10-16 真机 crash）：
  `Error code:140115 ... but not function ... assign value type: 'function'`
  → `aboutToAppear` 抛错 → `FRAMEWORK,PROCESS_KILL,JS_ERROR`。
  替代：`emitter` 或 `@State` 计数器。AppStorage 只能放 boolean/number/string/对象。

### ★★ 应用投屏看门狗：看「距上次出帧毫秒」，不看累计帧数（2026-10-15）
- `startCapture` 返回 0 **只代表管线建起来了，不代表持续出帧**。
- 设置页投屏区诊断面板：`出帧 / 断流计时 / 编码尺寸 / 结论`。
  数据源：`carlifidec.captureEncodedSize()` + `ScreenCaptureSource.diag().frames`（每秒采样）。
- **判读口径**：`frames` 累计**只增不减**是正常历史 → **停止增长才可疑**；
  `castLastOutMs`（距上次出帧）**一直涨 = 已断流** ← 硬指标；
  `fps` 归零 + `lastOut` 增长 → 确定断流，UI 标红。
- ⚠️ **局部验证路径的回调原来是个空函数**，导致面板永远 0。现已接 `onCastFrame()` 打点。
- ⚠️ **ArkUI 定时器在切后台/息屏可能被冻结 → 面板数值停更 ≠ 断流**。车机画面才是最终判据。

## T. 遗留问题与已修 bug 档案

- **★ 推流通路已实测通过（2026-10-13 / 10-15）**：`mock_hu.py` 连真机 20 项 / 25 项全过，
  含 `VIDEO(8240) 收到 131073 视频帧` + H.264 Annex-B 起始码；大哥截图确认
  **车机侧百度 CarLife 窗口完整上屏**。保活 65563 ×350 失败 0、车机视频心跳 ×380。
  **但真实车机/盒子仍未连上**（盒子为小米模式，P2P 不通属预期）→ 端到端尚未打通。
- **★★ 管线自杀的真根因：帧回调错绑（2026-10-15 真机抓到，已修）**：
  `napi_init.cpp::StartHmi` 签名 `startHmi(options, onFrame, onError?)`（args[1]=onFrame, args[2]=onError），
  帧桥 `g_frameTsfn` 曾错绑 **args[2]** → 每帧 H.264 都进错误回调 →
  `[画面] 错误([object ArrayBuffer]): 0` → ArkTS `stopStreaming()` 自杀。
  修复：改 `args[1]` + ArkTS 加 `typeof code !== 'number'` 兜底。
  **教训：错误信息里参数类型完全对不上 → 先查回调接线/参数错位，别猜错误码语义。**
- **★ 渲染器两后端均已实测**：CPU 位图后端（模拟器，`runHmiSelfCheck` 落 PNG 成功，
  首页 1670 种颜色 = 中文字形真被栅格化）；**GPU OnScreen 后端真机启动成功**。
  用法：设置页「离线自检（不碰编码器）」，产物 `files/hmi_{home,navi}.png`。
- **★ 切后台仍出帧已真机实锤（2026-10-15）**：手机前台是微信、App 在后台，
  保活 ×300→×320 全成功、车机心跳持续，大哥确认车机画面正常 —— **A1 自绘相对录屏的核心卖点首次实锤**。
- **待查（未解释）**：某次真机推流中 `mock_hu` 只收到 2 帧，而 App 侧计数仍在涨、
  `kbps` 读数显示 `3`。两者口径对不上 —— **下次上真机先复现再定位，别当结论用**。
- **观察到一次断线自恢复（原因未定）**：12:18:21 心跳 18s 未到 + Socket not connected →
  管线自动重启重连成功。
- **hdc WiFi 调试技巧**：`hdc install` 报 `need connect-key` 时，用
  `hdc -t <ip:port> install` 显式指定 target；`hdc discover`（UDP 8710）手机侧没广播，不可用。
- `setExtraOptions failed on :7240`（关 Nagle 失败），低延迟优化未生效，代码已容错。
- UDP 7999 发现端口未实现，靠手动填 IP。
- 官方手机端 `carlifeversion` / `carlifeSdkInt` **具体填什么值未取到**，本项目暂报 `1.0.0`（均 optional）。
- **`native_drawing` 没有任何图像编码接口** —— 要落图只能把裸像素交给 ArkTS 用 image kit 编。
- `tools/static_check.mjs` 的 5 处 DIFF + 1 处 MISS 属参考值过时 → **F 节**。
- 触控注入（无障碍）—— **大哥 2026-10-13 明确暂时搁置**，探针已装待开启 → **L/M 节**。
- **★ 过期 HAP 副本陷阱（2026-10-16 自己踩）**：曾 `cp entry-default-signed.hap
  entry-default-release-signed.hap` 造了份旧副本，之后一直装旧包、以为修复无效。
  **验证前先看产物时间戳，别信文件名。**

