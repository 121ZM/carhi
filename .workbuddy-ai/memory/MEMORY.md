# CarHi 项目长期记忆

在 HarmonyOS NEXT 上实现百度 CarLife **手机端**：手机采集/渲染画面，经 WiFi 推给真实 CarLife 车机
（车机是老安卓，只当显示器）。

> **只放「每轮都该知道」的铁律。** 深度细节（消息 ID 全表、USB/AOA、高德 SDK、盒子后台、
> Wi-Fi Direct、输入注入、渲染器细节、遗留 bug 档案、本机工具限制）→ 同目录 **`REFERENCE.md`**
> （A–T 节），按需读取。

## 1. 架构铁律

1. **手机是 TCP 服务端**，车机是客户端。监听 `7240 CMD / 8240 VIDEO / 9240 AUDIO / 9241 TTS /
   9242 VR / 9340 TOUCH / 9440 DATA`。**不需要 USB 从设备模式。**
2. **画面两条互斥通路，共用同一个硬件编码器**（切换走完整 stop→start，不能热替换）：
   - `NativeHmiSource` —— native `HmiRenderer`（`OH_Drawing`）自绘 → 编码器输入 Surface；
   - `ScreenCaptureSource` —— `OH_AVScreenCapture` 采集真实屏幕（可录到高德 App）。
   - 由 `EngineHolder.setFrameSourceFactory()` 选择；「应用投屏」按钮设 `forcedCapture`。
3. **★ 手机屏幕 ≠ 车机画面，两条独立通路**：手机屏幕 = ArkUI `pages/Index.ets`；
   车机画面 = native 画的那张图，**不显示在手机上**。唯一耦合 = `EngineHolder.pushHmi()`
   + `startFallbackPush()` 截图兜底（**只在 `frameSource.isFallback == true` 时跑**）。
4. 后台保活用 `BackgroundMode.AUDIO_RECORDING`(=3)，**不要加 `LOCATION`**（无定位业务，
   会被 `SYSTEM_SUSPEND_LOCATION_NOT_USED=8` 挂起；挂起比不申请更糟）。已移除。
5. 音频不碰蓝牙 API，走系统 A2DP。

## 2. 协议真值源

- **★ `refs/carlife_proto/*.proto`（93 个）** —— 官方手机端 `bdc_16031.apk` 原样提取，
  **唯一权威 wire-format 依据**。（`refs/` 被 gitignore。）
- ⚠️ 旧记忆里的 `refs/OFFICIAL_PROTOCOL.md` **本机已不存在**。
- `tools/mock_hu.py` —— 模拟车机 + proto 一致性校验器。`--host/--duration/--hb-hz`，
  `--strict` 有 FAIL 非零退出。2026-10-16 真机 **25 过 / 5 失败**（5 个全是未开通的
  AUDIO/TTS/VR/TOUCH/DATA 业务）。
  ⚠️ **它自己也会打印 `[CMD] 对端关闭连接`**（自己 `close()` 时 `_reader` 的 recv 也返回空）
  —— **两种情况的日志一模一样，不能用来判断谁先断**。

## 3. 握手主链路（手机端视角）

```
收 98305 → 发 65538(matchStatus=1) → 发 65540 设备信息   ★ 立即主动发，不等后续消息
收 98343 → 发 65609 鉴权响应 + 65611 鉴权结果 + 65617 特征配置请求（65609 必须最先）
收 98307 → 仅记录（异步，不回包）    收 98311 → 发 65544 编码参数
收 98313 → 开始推流 131073
```

- **踩坑**：曾把「发 65540」绑在「收 98307」上 → 互等死锁。**98307 / 98343 都是异步消息。**
- **★ 65617 请求体为空是正常的**：`CarlifeFeatureConfigList` 全是 HU 侧字段 → 属于 98386。
- **★ 65540 字段号**：`token=22`、`btaddress=23`、**`carlifeversion=24`**、`carlifeType=25`、
  `year=26`、`carlifeSdkInt=27`。曾把 `carlifeversion` 写在 22 → 车机收不到版本号。（全表 → H）

## 4. 心跳与鉴权超时（车机端仅两处主动断开）

依据车机端 APK 反编译（`a/a/a/a/m/k/a/c.java`）：

1. **心跳超时**：车机每 1000ms 经 VIDEO(8240) 发 `131074`，发前判
   `now - 最后收到手机消息 > 5000ms` → 断开。**要求「手机 5 秒内要有任意消息到达」**。
   本项目每 1000ms 上报 `65563 MD_FOREGROUND` 维持。
2. **鉴权超时**：车机收到手机 **65540** 时启动 **30 秒**定时器，到期断开。
   **取消它的唯一路径**：收到 **65609 且 `encryptValue` 非空**（内容不校验）。

- **★ 历史最大掉线坑**：`onHuAuthenRequest()` 曾只回 65611、**从不发 65609** → 每 30~62 秒稳定掉线。
  修复：**先发 65609 再发 65611**（顺序不可颠倒）。`verifyCode` 用 FNV-1a 产出
  `"2.0;<randomValue>;<digest>"` 即可（车机只校验非空）。

## 5. 视频通道 / 控制消息 / 采集

- **★ 入站数据「每条通道都要派发」**：曾只对 `CHANNEL_CMD` 分支 → 车机判失联、周期重连。
  现已加 `onVideoMessage` + `onOtherMessage(channel, msg)`。官方对 131074 **只读不回**。
- **★ TOUCH(9340, Ch6) 是车机→手机的触控通道**，丢了就是「车机上点不动」。现已接收 + 落日志。
  **真正注入手机 UI 暂未做**（非 root 只有无障碍一条路；`CONTROL_DEVICE` 四口全不通），
  2026-10-13 明确搁置。→ **L/M 节**。
- 官方 `CommonParams.java:297-305` 常量（**以此为准**）：`98311 INIT / 98313 START /
  **98314 PAUSE**（曾错写 98316）/ 98315 RESET / **98316 FRAME_RATE_CHANGE**（仅调帧率，
  绝不重启管线）/ 65549 FRAME_RATE_CHANGE_DONE / 65551 INIT_DONE`。
- 编码器（`canvas_encoder.cpp`）：车机经 `65544` 下发的宽高**真的用于配置编码器**。

## 6. ★★★ 「投屏时切应用掉线」= 已排除 App 侧（2026-10-16 实测定型）

**结论：切后台不会掉线。真因是「外部 peer 反复重连，把旧连接顶掉」。**

- **铁证 A（切后台 23 秒零异常）**：`12:06:08 onBackground` → `12:06:31 onForeground`，
  期间车机视频心跳 ×480→×580 **连续**、`65563` 保活 ×50/×60 **连续**、
  **0 次 `通道 N 已断开`、0 次 `continuousTaskSuspend`**。
- **铁证 B（前台也照样断）**：`12:06:49 通道 1 已断开` 时 App **已在前台** ⇒ 与前后台无关。
- **铁证 C（谁断的）**：`Server accept new client, fd=73 clientfd=83` → `js invoke
  TcpConnectionClose` → `通道 1 已断开`。代码依据 `transport/ChannelServer.ets:118`：
  ```ts
  // 单通道只保留一个活跃连接（CarLife 语义：一条通道一个连接）
  if (this.conn !== null) { this.closeConnection(); }
  ```
- **★ 因果方向（之前读反了）**：`通道 N 已断开` → `pipeline stopped` → `source.stop()`
  → `[投屏] 采集已停止` → native `OH_AVScreenCapture_StopScreenCapture`。
  **采集停止是后果，不是原因。**
- **外部 peer**：连来自 `192.168.0.131`（= 宿主机自己），自称 `samsung/SM-N9860`、
  请求 `1280x720@60fps`、`HU_INFO` **347 字节** ⇒ **与仓库 `mock_hu.py` 不是同一个脚本**
  （后者 HU_INFO 49 字节、30fps、真机解析出 `brand=` 是空的）。按 17~80s 不规则间隔反复重连。
- **★ 定位手法**：`hdc -t <ip:port> shell "cat /proc/net/tcp"` 解出 7 个端口
  （7240=0x1C48 / 8240=0x2030 / 9240=0x2418 / 9241=0x2419 / 9242=0x241A /
  9340=0x247C / 9440=0x24E0）`state=01` 的**对端 IP**。⚠️ 宿主机 `netstat -ano` 在本沙箱
  看不到这些连接（连 hdc 自己的都查不到），**别用它下结论**。
- **★ 方法论教训**：「A 发生在 B 之后」≠「A 导致 B」。先确认"谁先动的手"，再谈"为什么"。
- **★ 附带发现（待修）**：切回前台时有一次**自动**的 `stopAppCast()` → `startAppCast()`
  往返，白重建一次采集管线。`stopAppCast()` 全仓只有按钮 `onClick` 一个调用点
  （`Index.ets:802`），**触发源未找到**。→ **O 节**

## 7. 构建与部署

- 构建 `bash tools/build.sh`；**默认 `MODE=debug`** → 要 release 须 `bash tools/build.sh release`。
  ★ **输出一律用 `tail`；`head` 会 SIGPIPE 杀掉构建**（报 `MODULE_NOT_FOUND`）。
- IDE：DevEco Studio 26.0.0.851（`E:\Program Files\Huawei\DevEco Studio`）。
  HarmonyOS 7.0 = API 26 = 语义化 `26.0.0`。
- `abiFilters` 需含 `arm64-v8a` + `x86_64`，缺了报 `9568347`。
- **签名**：`products[0]` 必须有 `"signingConfig": "default"`，否则 `9568320`。
  材料 `C:\Users\dev\.ohos\config\default_harmony_*.{p12,cer,p7b}`（仓库 public，
  已 `git update-index --skip-worktree`，**换机器要重设**）。
- 安装：**必须 cd 到产物目录用相对路径**（hdc 对 Windows 绝对路径会拼错）：
  `cd harmony/entry/build/default/outputs/default && hdc install -r entry-default-signed.hap`。
  包名 `com.carhi.carlifephone`；显示名 **autoCar**。
  ⚠️ **别复制 HAP 副本**（曾 `cp` 出旧副本后一直装旧包）—— **看时间戳，别信文件名**。
- ArkTS 坑：`@kit.ConnectivityKit` **不导出 `BusinessError`**（从 `@kit.BasicServicesKit` 导）；
  `WifiP2PConfig` 字段是 **`goBand`**，**没有 `groupOwnerIntent`**。
- **★ 窗口方向由运行期代码控制，module.json5 的 orientation 不生效**：
  `EntryAbility.onWindowStageCreate` 里 `win.setPreferredOrientation(...)` 才是真值。

## 8. 调试环境

- **真机 `MRT-AL10`**（nova 14 Ultra）HarmonyOS 7.0.0.109，API 26。**IP/端口会变**，
  `hdc tconn <ip>:<port>`（**不是 5555**）。最近端点 `192.168.0.186:39713`。
  ⚠️ **宿主机自己 IP = `192.168.0.131`**（与旧记录"车机 IP 192.168.0.131"撞车，旧记录已失效）。
- **★ hdc 连接在两次调用之间会掉** → 每条命令都要重新 `hdc tconn`，且用 `-t <ip:port>`
  指定目标，否则报 `need connect-key`。**建议写个 tconn+exec 的包装脚本。**
- **★ 找不到真机**：`hdc list targets` 为 `[Empty]` → `ipconfig` 拿网段 → 多线程 ping 扫全段
  → 探 `7240/8240/5555`（**开着 = 手机上 CarHi 在跑**）。结论通常是**手机侧无线调试被关了**。
- 真机与宿主机同网段 → **可直连真机端口，无需 fport**（**hdc 挂了也能这样绕开**）。
- **★ 真机屏幕（车机模式）实际是 `1920×720` 横屏**。
- ⚠️ **锁屏时 `aa start` 会被拒**（`10106102 screen is locked`）。
- 模拟器 API 26 x86_64，WiFi 走 NAT → 需 `hdc fport`；**没有视频编码器**。
- ⚠️ **不要对 IDE 正在用的 hdc server 执行 `hdc kill`**。
- ⚠️ **`hilog -e <pattern>` 后台进程会空转烧 CPU**。用
  `nohup timeout <N> hilog > /data/local/tmp/x.log 2>&1 &`（会自杀、无残留）。
- **★ 本 App 日志 tag 是 `CarHi` / domain `A00001`**（native 侧 `CarHiNative`），**不是** `JSAPP`。
  **`hilog -x` 缓冲轮转极快（几万行/分钟），必须落文件抓**，否则回头什么都查不到。
- **★ grep 日志时先看完整 tag 列表再定模式**：曾把 `[画面]` 写成 `画面源`，漏掉
  `[画面] 已开始产出`；`capture encoder output` 也不含 `inner audio`。**模式写窄了会得出错误结论。**
- hdc 路径：`E:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe`。

## 9. 导航数据来源（★ 只有高德 SDK 一条路）

| 路线 | 结论 |
|---|---|
| Car Kit `navigationInfoMgr`（取导航数据） | ❌ **判死且已整体移除**：`NavigationController` 只有 2×update（写）+ register/unregister，**无读取**；权限 / skills / metadata / 探针代码**已从仓库删除**（→ R 节） |
| 系统级屏幕镜像（CarWith / CarLife 手机端那套） | ❌ 判死（需 system\|privileged 权限） |
| DV Engine / HiCar 车机侧 SDK | ❌ 判死（系统签名 / 企业主体） |
| **高德导航 SDK `@amap/amap_lbs_navi`** | ✅ **已打通**（→ Q 节） |
| **应用投屏（`OH_AVScreenCapture`）** | ✅ **已打通**（→ §6 与 S 节） |

- **⚠️ 教训**：`801 Capability not supported` 在 **debug 包**下也会出现，
  **不能拿 debug 包的负结果给整个能力判死**。
  （判 debug/release 看 HAP 内 `module.json` 的 `app.buildMode`/`app.debug`；
  ⚠️ `app.apiReleaseType` 两边都是 `Release`，区分不出来。）

## 10. 与盒子/车机的三条连接路线

| 路线 | 载体 | 状态 |
|---|---|---|
| A. Wi-Fi Direct | P2P + 7 个 TCP 端口（`WifiProbe.ets` 已实现） | 能发现 `Box_259E`，未连成 |
| B. 搜索蓝牙配对 | BLE 广播 + 经典蓝牙 SPP（RFCOMM） | 未实现 |
| C. ADB over IP + scrcpy | `com.baidu.supercast.link` / `AdbMdns` | 未实现（小米/vivo CarWith 走这条） |

- **★ 盒子固件 V0.2.7 的「搜索蓝牙配对」模式与「自动弹窗/BLE」互斥**，在盒子后台
  （`192.168.0.1`）里选；**CarLife 公版 + 小米 CarWith 都要用「搜索蓝牙配对」**。
  **盒子现已改成小米模式** → P2P 直连不通属预期。
- **★ 网段冲突是「能连上但老掉线」头号原因**：手机 P2P 口 `192.168.0.2/24` 与家里路由器
  `HNJJDT`（`192.168.0.0/24`）同段，`/proc/net/route` 里**没有 p2p 路由**。
  **解法：测盒子时断开家里 WiFi。**
- **★ P2P 密码来自官方 proto 注释**：`// p2p ssid like "box, 88888888, 5745, 2" encrypted`
  → 「名字, **密码 88888888**, **频率 5745MHz**, **频段 2**」。
  **旧记忆「passphrase 传空串即可」已被推翻**（= WPS PBC，必被拒）。
  其余（权限、判据陷阱、大端 IP、盒子后台三前提）→ **B/C/D 节**。

## 11. 界面与渲染器

- **★ 手机屏幕 ≠ 车机画面**（见 §1.3）。手机侧 `build()` 就是 `Stack { SettingsPage() }`；
  车机页面切换入口在设置页顶部「车机画面 [首页][导航]」，`@State page` 默认 **1（导航）**。
- **★ 静态字段必须镜像成 `@State` 才会刷新**（300ms `tickTimer` 变化时才同步）。
- **★ 渲染器跨实例共享文件级静态资源 → 必须加锁**：`g_fill`/`g_pen`/`g_textSlots` 是文件级静态，
  在线推流中点「离线自检」= **use-after-free**。已加 `std::mutex g_drawMutex`：
  `RunSelfCheck` 全程持有，`RenderOnce` 两条分支在 `DrawFrame` 外加锁。
  **新增任何动这些静态资源的函数，都要先拿这把锁。**
- **★ CarWith 导航卡版式**（`DrawNaviGuideCard`）：进度条**铺满整卡当背景**；左侧图标宽 `w*0.24`
  且 1:1 居中；字号按卡宽比例 —— 距离 `0.12w` / 单位 `0.07w` / 动作 `0.071w` / 路名 `0.06w`。
  原文与色值 → **P 节**。
- **★ ArkUI 禁令：`AppStorage.setOrCreate` 不接受函数**（真机 crash `Error code:140115`
  → `PROCESS_KILL,JS_ERROR`）。替代：`emitter` 或 `@State` 计数器。

## 12. 已知遗留问题

- **★ 推流 + 音频通路均已实测通过（2026-10-16）**：`mock_hu.py` 全绿（握手/65609/65544/
  视频帧/65563 全过），音频 `MEDIA_INIT(48000/2ch/16bit) → 500 帧 PCM×3840B` 在 9240 全程畅通，
  **3840B÷20ms=192000B/s 坐实 S16LE**。**但真实车机/盒子仍未连上**（盒子为小米模式）→ 端到端未打通。
- **★ 外部 peer 实锤**：有个自称 samsung/SM-N9860 的客户端周期性重连全部 7 通道（判据：
  hilog 里 `HU_INFO` **347 字节**；mock 是 49 字节），会把当前连接踢掉。跑 mock 前先确认没它。
- **★ mock 回归的沙箱假象**：沙箱代理会**杀掉沙箱内 python 的 TCP 连接**（t+4~5s）且
  **mock 退出后还替它挂连接 20~35 秒**。mock 的「全程保持连接」已改为**心跳循环退出瞬间快照**
  判定，MEDIA_STOP 警告加了时间戳门控。宿主机 netstat **看不到沙箱内 python 的连接**。
- **★ 管线自杀的真根因：帧回调错绑（已修）**：`StartHmi` 的 `g_frameTsfn` 曾错绑 `args[2]`
  → 每帧进错误回调 → ArkTS `stopStreaming()` 自杀。**教训：错误信息里参数类型完全对不上
  → 先查回调接线/参数错位，别猜错误码语义。**
- **★ 切后台仍出帧已真机实锤（2026-10-15 / 10-16）** —— 自绘与录屏两条路都成立。
- **★ 待查**：切回前台时的一次自动 `stopAppCast()`→`startAppCast()` 往返（见 §6）。
- 其余（渲染器两后端实测、`native_drawing` 无编码接口、断线自恢复、`static_check` 参考值过时等）
  → **T 节**。
