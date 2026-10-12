# CarHi 项目长期记忆

## 项目本质
在 HarmonyOS NEXT 上实现百度 CarLife **手机端**，通过 WiFi 把手机屏幕推给真实 CarLife 车机。
场景：车机是老旧安卓，跑不动高德车机版，用手机渲染、车机当显示器。

## 架构铁律
1. **手机是 TCP 服务端**，车机是客户端。手机监听
   `7240/8240/9240/9241/9242/9340/9440`，车机主动连。不需要 USB 从设备模式。
2. **采集+编码必须在 Native C++**。ArkTS 无视频编码 API，AVScreenCaptureRecorder 只能录文件。
   链路：`OH_AVScreenCapture_StartScreenCaptureWithSurface` → Surface → `OH_VideoEncoder`
   → H.264 Annex-B → threadsafe function → JS → TCP 8240。
3. **后台保活用 `BackgroundMode.AUDIO_RECORDING`**（=3，官方用途含 screen capture），
   不是 `DATA_TRANSFER`（=1）。
4. 音频不碰蓝牙 API，走系统 A2DP。

## 协议真值源
- **`refs/OFFICIAL_PROTOCOL.md`** —— 逆向官方 APK 得到，**最权威**。
- `refs/carlife_pc_tool/` —— Python 车机端模拟器（逆向自真实车机），可作联调对端。
- `tools/mock_hu.py` —— **本项目自建的极简模拟车机**，可连 7240/8240 并按频率发 131074
  心跳。配合 `hdc fport tcp:8240 tcp:8240` 即可在模拟器/真机上做无车机联调。
- 官方 APK 反编译产物在 `/tmp/carlife_src`（临时，如需复现见 OFFICIAL_PROTOCOL.md 第八节）。

## 视频通道（8240）入站数据**必须处理**
车机经 VIDEO 通道下发 `131074` 心跳。官方 `ConnectManager.java:559-576` 用专职线程
每 200ms 轮询读取，收到即刷新 `mHeartBeatTime`；超时阈值 **6000ms**
（`checkHeartBeatTask` 每秒检查）→ 判定断线。

**踩坑记录**：本项目 `ChannelServer.ets` 曾写成
`if (this.channel === CHANNEL_CMD) { onCommandMessage(msg) }`，
把视频通道的入站包**全部丢弃** → 车机判定手机失联 → **周期性断开重连**。
修复：新增 `onVideoMessage` 回调并把视频通道接进去。

**注意**：官方对 131074 只"读"不"回"，心跳保活不靠回包。

## ★ 车机端心跳与鉴权超时（反编译 `CarLife4.0车机端.apk` 确凿）

车机端 APK：`C:\Users\ZM\Documents\xwechat_files\zi---min_93f7\msg\file\2026-05\CarLife4.0车机端.apk`
（用户提供）。车机端跑在本机 **Hyper-V 虚拟机**（`vEthernet (MyApps vSwitch)`，
172.29.224.x 网段，VM MAC `00-15-5d-*`），经 NAT 出网，源 IP 显示为宿主机
`192.168.31.65` —— 所以宿主机 netstat 看不到它的连接，别被误导。

反编译命令（jadx 需 JAVA_HOME）：
`export JAVA_HOME="/d/dev/Huawei/DevEco Studio/jbr"; /tmp/jadx/bin/jadx -d /tmp/hu_src --no-res "<apk>"`
核心 SDK 在混淆包 `a/a/a/a/`；关键文件 `a/a/a/a/m/k/a/c.java`。

### 车机端仅两处主动断开
1. **心跳超时**（`c.java:41-67`）：车机每 **1000ms** 经 VIDEO(8240) 发 `131074`，
   发前判断 `now - 最后收到手机消息 > 5000ms` → `context.a()` 断开。
   **要求是「手机 5 秒内要有任意消息到达」**，不是等回心跳包。
   字段 `f` 在 `g0()`（onReceiveMessage，拦截所有通道）里刷新。
   手机端维持办法：周期上报 `65563 MD_FOREGROUND`（本项目每 1000ms）。
2. **鉴权超时**（`c.java:182` + `184-233`）：车机收到手机的 **65540（设备信息）**
   时启动 **30 秒**定时器；到期即打印 `"Carlife Connect authentication failed."`
   并断开。**取消它的唯一路径**是收到手机的 **65609（MD_AUTHEN_RESPONSE）**
   且 `encryptValue` **非空**（内容不校验）。

**踩坑记录（本项目最大掉线坑）**：`StateMachine.onHuAuthenRequest()` 曾只回
`65611` 而**从不发 65609** → 车机 30 秒定时器必然到期 → **每隔 30~62 秒稳定掉线**。
修复：`onHuAuthenRequest(msg)` **先发 65609 再发 65611**（顺序不可颠倒）。
`verifyCode` 用 FNV-1a 摘要产出 `"2.0;<randomValue>;<digest>"` 即可（车机只校验非空）。

官方手机端参照：`PrivateKeyManager.encryptContentProcess()`——
`randomValue` 形如 `"2.0;<时间戳>"`，走 native `EncryptionUtils.getVerifyCode()`
（`.so` 内实现）；否则 RSA 兜底（私钥硬编码在 `PrivateKeyManager.PRIVATE_KEY`）。

## 视频控制消息常量（官方 `CommonParams.java:297-305`，务必以此为准）
| ID | 常量 | 含义 |
|---|---|---|
| 98311 | `MSG_CMD_VIDEO_ENCODER_INIT` | 编码参数协商 |
| 98313 | `MSG_CMD_VIDEO_ENCODER_START` | 开始推流 |
| **98314** | `MSG_CMD_VIDEO_ENCODER_PAUSE` | 暂停（**曾错写为 98316**） |
| 98315 | `MSG_CMD_VIDEO_ENCODER_RESET` | 重置通道 |
| **98316** | `MSG_CMD_VIDEO_ENCODER_FRAME_RATE_CHANGE` | **仅调帧率，绝不重启管线** |
| 65549 | `MSG_CMD_VIDEO_ENCODER_FRAME_RATE_CHANGE_DONE` | 帧率变更回执 |
| 65551 | `MSG_CMD_VIDEO_ENCODER_INIT_DONE` | 编码器就绪 |

## 采集状态码（OH_AVScreenCaptureStateCode）处理原则
- **5/6/7（MIC_UNAVAILABLE / MUTED / UNMUTED）**：本项目不走麦克风（音频走 A2DP），
  **必须忽略**。曾把非正常状态一律当"中断"去重启采集，导致每 2 秒自杀式重建管线。
- **8/9（ENTER/EXIT_PRIVATE_SCENE）**：内容变化，采集未断，忽略。
- `RestartCapture()` 已加 **3 秒冷却**（`kRestartCooldownMs`），抑制重启震荡。

## 采集策略（消除录屏授权弹窗）
`screen_encoder.cpp` 的 `ApplyCaptureStrategyLocked()`，须在 `StartScreenCapture*` **之前**调用：
- `StrategyForPickerPopUp(false)` —— 启动后不弹 Picker（核心）
- `StrategyForKeepCaptureDuringCall(true)`
- `StrategyForCanvasFollowRotation(true)`

## 构建与部署
- 构建：`bash tools/build.sh`（脚本自动探测 DevEco/CLT 路径与 JBR）
- **ABI**：`build-profile.json5` 的 `abiFilters` 需含 `arm64-v8a`（真机）与
  `x86_64`（模拟器）。模拟器只支持 x86_64，缺了会报
  `code:9568347 install parse native so failed`。
- 签名：`build-profile.json5` 的 `products[0]` **必须**有 `"signingConfig": "default"`，
  否则报 `code:9568320 no signature file`。
- 安装：**必须 cd 到产物目录用相对路径**，hdc 对 Windows 绝对路径会拼错：
  `cd harmony/entry/build/default/outputs/default && hdc install -r entry-default-signed.hap`
- 包名：`com.carhi.carlifephone`

## 调试环境（真机 WiFi 调试，首选）
- **真机** `MRT-AL10`：`192.168.31.126:38957`，HarmonyOS 7.0.0.109，API 26。
  连接：`hdc tconn 192.168.31.126:38957`（端口是 **38957**，不是 5555）。
- 真机与宿主机同网段（`192.168.31.x`）→ **宿主机可直连真机端口**，
  无需 `fport`。直接 `python tools/mock_hu.py --host 192.168.31.126`。
- 模拟器：`Emulator.exe`，API 26，x86_64，WiFi 走 NAT（`192.168.76.9`，
  宿主机不可达）。连接走 `hdc fport tcp:7240 tcp:7240` 等转发。
- ⚠️ **不要对 IDE 正在使用的 hdc server 执行 `hdc kill`** ——
  会断开调试会话，并可能导致模拟器进程退出。出问题时请用户从 IDE 侧重连。

## 联调工具
- `tools/mock_hu.py` —— **完整握手版模拟车机**。按官方时序发
  98305→98343→98307→98376→98311→98386→98313，并后台解析手机端回包；
  同时在 VIDEO 通道发 131074 心跳。用法：
  `python tools/mock_hu.py --host 192.168.31.126 --duration 60 --hb-hz 5`
- 已实测：真机上握手全链路通过、推流 131073 持续到达、心跳稳定接收。

## 握手主链路（手机端视角，官方确认）
```
收 98305  → 发 65538(matchStatus=1)
          → 发 65540 手机设备信息   ★ 立即主动发，不等车机任何后续消息
收 98343  → 发 65611 鉴权结果 + 65617 特征配置请求
收 98307  → 仅记录（异步，不回包）
收 98311  → 发 65544 编码参数
收 98313  → 开始推流 131073
```
**踩坑记录**：曾把「发 65540」绑定在「收 98307」上，导致与车机互等死锁，真机卡在 30%。
**教训**：98307 / 98343 都是异步消息，不能作为时序依赖；版本匹配成功即应主动推进。

## 构建与部署
- 构建：`bash tools/build.sh`（脚本自动探测 DevEco/CLT 路径与 JBR）
- 签名：`build-profile.json5` 的 `products[0]` **必须**有 `"signingConfig": "default"`，
  否则报 `code:9568320 no signature file`。
- 安装：**必须 cd 到产物目录用相对路径**，hdc 对 Windows 绝对路径会拼错：
  `cd harmony/entry/build/default/outputs/default && hdc install -r entry-default-signed.hap`
- 包名：`com.carhi.carlifephone`
- SDK/IDE：DevEco Studio 26.0.0.851，HarmonyOS 7.0 = API 26 = 语义化 `26.0.0`。
  自 DevEco 6.0.0(20) 起 SDK 内嵌于 IDE，无法单独升级。
- 真机：HUAWEI MRT-AL10，HarmonyOS 7.0.0.109。IP 曾在 `192.168.31.126`。

## 关键 ID 速查（官方值）
98305 HU_PROTOCOL_VERSION / 65538 MD_MATCH_STATUS / 98307 HU_INFO /
65540 MD_INFO / 98343 STATISTIC_INFO / 65609 MD_AUTHEN_RESPONSE /
65611 MD_AUTHEN_RESULT / 98376 HU_AUTHEN_REQUEST / 98378 HU_AUTHEN_RESULT /
65617 MD_FEATURE_CONFIG_REQUEST / 98386 HU_FEATURE_CONFIG_RESPONSE /
98311 HU_VIDEO_ENCODER_INIT / 65544 VIDEO_ENCODER_INIT / 98313 VIDEO_ENCODER_START /
65551 VIDEO_ENCODER_INIT_DONE / 131073 VIDEO_DATA /
65560 SCREEN_ON / 65561 SCREEN_OFF / 65562 SCREEN_USERPRESENT /
65563 FOREGROUND / 65564 BACKGROUND / 65574 MODULE_STATUS / 131074 VIDEO_HEARTBEAT

## 已知遗留问题
- `setExtraOptions failed on :7240`（关 Nagle 失败），低延迟优化未生效，代码已容错
- UDP 7999 发现端口未实现，靠手动填 IP
- 验证后台采集（切后台画面是否持续）尚未完成
