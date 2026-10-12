# 项目进展与交接（HANDOFF）

> 用途：换机器继续开发时，**先看这一份**。它记录当前进度、已确认的结论、待办与踩过的坑。
> 配套：`PLAN.md`（完整技术方案）、`refs/OFFICIAL_PROTOCOL.md`（官方协议逆向对照）
> 最后更新：2026-10-12

---

## 一、项目目标（一句话）

在 **HarmonyOS NEXT** 上实现百度 CarLife 的**手机端**：把手机整屏经 CarLife 协议推给车机。
车机是老旧安卓（跑不动高德车机版），因此**手机负责渲染，车机只当显示器**。

- 仓库：`https://github.com/121ZM/carhi.git`
- 范围：**仅推流**。不做触控回传、不做音频（走蓝牙 A2DP 独立通道）
- 包名：`com.carhi.carlifephone`（注意：不是 `com.baidu.carlife`）

---

## 二、当前状态总览

| 能力 | 状态 |
|---|---|
| WiFi 直连推流 | ✅ **真机验证通过**，长时间稳定 |
| 协议握手/鉴权/心跳 | ✅ 已对齐官方（含 65609 关键修复） |
| 屏幕采集 + H.264 编码 | ✅ 可用 |
| 服务默认开启 | ✅ 进入首页自动启动 |
| 长时任务保活 | ✅ 全生命周期持有 |
| 录屏授权弹窗优化 | ✅ 已做门控（系统强制弹窗无法消除） |
| **USB 直连** | ⏳ **待实测**（诊断模块已就绪） |
| 无线盒子（QH3002） | ⏸ 未开始，等 USB 结论 |

---

## 三、已解决的关键问题（都有真机验证）

### 3.1 ★ 30 秒周期性掉线（最大根因）

**根因**：车机端收到手机 `65540`（设备信息）后，会启动一个 **30 秒鉴权定时器**；
只有收到手机回发的 **`65609 MD_AUTHEN_RESPONSE`** 才会取消它。
本项目原实现**只回 `65611`，从不发 `65609`** → 30 秒后必然被车机断开。

**依据**：反编译车机端 APK（`CarLife4.0车机端.apk`）关键文件 `a/a/a/a/m/k/a/c.java:182/68-82/184-233`。

**修复**：`core/StateMachine.ets` 新增 `CarlifeAuthenRequest/Response`，
`onHuAuthenRequest(msg)` **先发 65609、再发 65611**（顺序不可颠倒）。

**验证**：修复前 30~62 秒必断；修复后连续 100+ 秒稳定，保活 `65563 已发送 ×120，失败 0`。

### 3.2 车机端心跳超时机制

车机每 **1000ms** 经 VIDEO(8240) 发 `131074`，发前判断 `now - lastRecv > 5000ms` 就断开。
字段在 `onReceiveMessage`（拦截**所有通道**消息）里刷新 —— 语义是「手机 5 秒内要有任意消息到达」。

**对策**：手机端每 1 秒发 `65563 MD_FOREGROUND` 保活（已实现）。

### 3.3 服务被反复重启

`pages/Index.ets` 的 `aboutToDisappear()` 曾无条件调 `engine.stop()`，
导致切后台/页面重建 → 连接反复重建。**已移除**，改为引擎提升为模块级单例 `EngineHolder`。

### 3.4 录屏授权弹窗反复弹

鸿蒙手机端**录屏授权弹窗是系统强制的，应用无法记住、无法绕过**（官方文档《AVScreenCapture
录屏基础流程》「约束与限制」明确写明）。`StrategyForPickerPopUp(false)` 只关 PC 的
「选择共享内容」弹窗，对手机无效；唯一免弹窗权限 `CUSTOM_SCREEN_RECORDING` 仅 PC/2in1 可用。

**对策**：新增 `core/CaptureGate.ets` 把弹框压到系统下限 ——
一次会话最多主动启动 3 次；连续失败 2 次判定用户拒绝 → **停止一切自动重试**；
用户可点「重新授权」手动恢复。**关键收益：采集中断重试不再重复弹框**。

---

## 四、当前待办：USB 直连

### 4.1 为什么先做 USB

用户真实车机是**第三方无线盒子转无线**（耘电车联 QH3002）。盒子通常按**官方 CarLife App
的行为**对接，可能校验包名/签名。**先用 USB 直连把协议正确性验证干净**，再引入盒子，
否则盒子的问题会和协议问题混在一起，无法排查。

### 4.2 USB 与 WiFi 的关系（用户判断正确）

**协议层完全一样，只是触发/承载方式不同。**

- 监听地址已是 `'0.0.0.0'`（`transport/ChannelServer.ets:99`），**USB 虚拟网卡上的连接现在就能收**
- 角色不变：**手机始终是 TCP 服务端，车机主动连**（USB 下同理）

### 4.3 关键未知：USB 下走哪条路

| 路径 | 机制 | 手机端改造量 |
|---|---|---|
| **路 A：CDC-ECM / RNDIS** | 车机把手机当 USB 网卡，双方各得 IP，跑 TCP | **零改造** ✅ |
| **路 B：AOA 配件模式** | 不建 IP，字节流直接走 USB 批量端点 | **需新写传输层** ⚠️ |

**两者改造量差一个数量级，必须实测分辨，不能猜。**

### 4.4 已实现的诊断工具

`core/UsbProbe.ets` + 界面「USB 直连诊断」卡片（`pages/Index.ets`）：

- `UsbLinkKind{NONE, IP_NETWORK, ACCESSORY, BOTH}`
- 三路采集：`getDevices()` / `getAccessoryList()` / `getAllNets()`+`getConnectionProperties()`
- 判定：有 USB 配件 → ACCESSORY；有非 wlan/lo/rmnet 网卡 → IP_NETWORK
- **只读**，不影响现有连接

**实测步骤**：装新版 → USB 线插车机 → 车机打开 CarLife → 应用内点「诊断 USB」→ 看结论。

### 4.5 鸿蒙 USB 能力（SDK 实证）

`@ohos.usbManager`（API 14+，本工程 API 26）**完整支持 USB Accessory 模式**：

```
getAccessoryList() / hasAccessoryRight() / requestAccessoryRight()
openAccessory() → USBAccessoryHandle.accessoryFd   // 拿到 fd 用 Core File Kit read/write
closeAccessory()
USBAccessory{manufacturer, product, description, version, serialNumber}
```

> ⚠️ `usbManager` 从 **`@kit.BasicServicesKit`** 导出，**不是** `@kit.USBKit`（后者不存在）。

---

## 五、无线盒子（QH3002）现状记录

- 型号：**耘电车联 QH3002**（"QH3002-CL-CL" 无线转换盒）
- 用户确认：**不走传统热点**，走**直连**
- 结合"蓝牙发现再连接" → 高度符合 **蓝牙带外配对 + Wi-Fi Direct(P2P) 点对点直连**
- 数据面仍是 **WiFi TCP 7 通道**（非 USB），与已跑通协议层一致
- 待确认：鸿蒙 `@ohos.wifiManager` 的 P2P 接口能否连该盒子
- 风险：盒子可能校验包名/签名，或要求官方蓝牙配网协议

---

## 六、环境与命令（换机器必读）

### 6.1 真机环境

| 项 | 值 |
|---|---|
| 设备 | `MRT-AL10`，HarmonyOS 7.0.0.109，API 26 |
| hdc | `<DevEco>/sdk/default/openharmony/toolchains/hdc.exe` |
| Bundle | `com.carhi.carlifephone` |

### 6.2 编译命令（**三个环境变量缺一不可**）

```bash
cd harmony
export DEVECO_SDK_HOME="<DevEco>/sdk"
export JAVA_HOME="<DevEco>/jbr"
export PATH="<DevEco>/jbr/bin:$PATH"      # ★ 少了这个会报 spawn java ENOENT
<DevEco>/tools/hvigor/bin/hvigorw --mode module -p product=default \
  -p module=entry@default assembleHap --analyze=normal --parallel --incremental --no-daemon
```

### 6.3 安装到真机

```bash
cd harmony/entry/build/default/outputs/default
hdc -t <手机IP:端口> install -r entry-default-signed.hap
```

> ⚠️ **必须 `cd` 到产物目录后用相对路径**，否则 hdc 会拼错路径。

### 6.4 签名限制（重要）

当前用的是 **DevEco 自动生成的调试证书**（p7b 中 `"type":"debug"`，绑定设备 UDID）。

**后果：这个包只能通过 hdc 安装，无法在手机上点开本地安装。**
`buildMode=release` 也改变不了这一点 —— 决定权在证书的 `type` 字段，不在编译模式。

要能本地安装/上架，必须去 **AppGallery Connect** 申请发布证书（`.cer` + `.p7b`），需开发者账号。

### 6.5 反编译工具链（如需重查协议）

```bash
export JAVA_HOME="<DevEco>/jbr"     # 不设会报 "JAVA_HOME is not set"
# jadx 位于 /tmp/jadx（临时目录，换机器需重装）
```

---

## 七、代码结构（本轮新增部分）

```
harmony/entry/src/main/ets/
├── core/
│   ├── CaptureGate.ets     ★ 新增：录屏授权门控（压弹框到系统下限）
│   ├── UsbProbe.ets        ★ 新增：USB 链路诊断（判路 A / 路 B）
│   ├── CarLifeEngine.ets     改：接入门控、新增 retryCapture()、拒绝时停止重试
│   ├── StateMachine.ets      改：65609 修复、保活计数
│   ├── BackgroundKeeper.ets  改：长时任务全生命周期
│   └── NativeCodec.ets       改：采集策略、重启能力
├── pages/
│   └── Index.ets             改：EngineHolder 单例、自动启动、
│                                「录屏授权」与「USB 直连诊断」卡片
└── transport/
    └── ChannelServer.ets     改：0.0.0.0 监听（USB 兼容基础）
```

---

## 八、下一步（按优先级）

1. **实测 USB 诊断** —— 确认走 路 A（零改造）还是 路 B（需写传输层）
2. 若路 A → 处理"USB 网卡就绪后监听"的边角，USB 直连基本完工
3. 若路 B → 实现基于 `accessoryFd` + Core File Kit read/write 的传输层
4. 再引入盒子 QH3002（WiFi P2P）

## 九、尚未修复 / 已知问题

- `video encoder error code=10`：`OnCodecError` 把 native 错误码直接当 `CaptureInterrupt` 用，语义不匹配（`screen_encoder.cpp`）
- `setExtraOptions failed` 低延迟优化（部分平台不支持，已容忍）
- UDP 7999 发现端口未实现（手动填 IP 已绕过）
- 长时任务常驻通知可考虑降级为静默通知
