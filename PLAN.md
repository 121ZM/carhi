# 鸿蒙版 CarLife 手机端 · 技术方案

> 目标：在 HarmonyOS NEXT 上实现 CarLife **手机端**，向真实百度 CarLife 车机推送导航画面（视频流）。
> 范围：**仅推流导航**。不做触控回传、不做车机遥控手机、音频走蓝牙独立通道。
> 撰写日期：2026-10-09

---

## 一、结论先行

**方案成立。** 协议已完整拿到（带官方混淆源码行号溯源），鸿蒙侧所需系统能力齐备，
唯一的工程风险集中在「屏幕采集权限」与「编码性能」两点，均有明确对策。

**关键发现（推翻了前期假设）**：

> **手机端是 TCP 服务端，车机是客户端。**
> 手机端在 `7240/8240/9240/9241/9242/9340/9440` 七个端口上 **监听**，车机主动来连。
> 因此 **不需要 USB 从设备模式** —— 这是前期判断「可能堵死」的那条路，现在完全绕开了。

---

## 二、协议规格（已从源码逆向核实）

### 2.1 通道与端口

| 通道 | 端口 | 用途 | 本项目是否实现 |
|---|---|---|---|
| 1 CMD | 7240 | 控制/信令 | **必须** |
| 2 VIDEO | 8240 | H.264 视频流 | **必须** |
| 3 AUDIO | 9240 | 媒体音频 PCM | 不做（走蓝牙） |
| 4 TTS | 9241 | 导航语音 PCM | 不做（走蓝牙） |
| 5 VR | 9242 | 语音识别 PCM | 不做 |
| 6 TOUCH | 9340 | 触控/按键 | 不做（仅监听不处理） |
| 7 DATA | 9440 | 车况传感器 | 不做（仅监听不处理） |

- **UDP 7999**：车端监听，手机端广播发现（无线连接入口）
- 源码依据：`sources/d/b/a/a/p/o/e/c.java:16`、`sources/d/b/a/a/p/o/e/d.java:146`

### 2.2 报文帧格式（全大端序 Big-Endian）

```
Channel 1 / 6  (8 字节头)：
  [uint16 payload_len][uint16 reserved=0][uint32 service_type] + payload

其他通道      (12 字节头)：
  [uint32 payload_len][uint32 seq_or_ts][uint32 service_type] + payload
```

- 源码依据：`sources/d/b/a/a/o/h/a.java:134-147, 204-228`
- **注意**：头长度按通道区分，这是最容易踩的坑

### 2.3 消息 ID（部分关键项）

| ID (hex) | 名称 | 方向 |
|---|---|---|
| 0x00018001 (98305) | HU_PROTOCOL_VERSION | 车机 → 手机 |
| 0x00010002 (65538) | MD_PROTOCOL_VERSION_MATCH_STATUS | 手机 → 车机 |
| 0x00018003 (98307) | HU_INFO | 车机 → 手机 |
| 0x00010004 (65540) | MD_INFO | 手机 → 车机 |
| 0x0001004B (65611) | MD_AUTHEN_RESULT | 手机 → 车机 |
| 0x0001804C (98380) | HU_AUTHEN_RESULT | 车机 → 手机 |
| 0x00010051 (65617) | MD_FEATURE_CONFIG_LIST | 手机 → 车机 |
| 0x00018052 (98386) | HU_FEATURE_CONFIG_LIST | 车机 → 手机 |
| 0x00018007 (98311) | HU_VIDEO_ENCODER_INIT | 车机 → 手机（含分辨率/帧率） |
| 0x00010008 (65544) | VIDEO_ENCODER_INIT | 手机 → 车机 |
| 0x00018009 (98313) | VIDEO_ENCODER_START | 车机 → 手机（开始推流） |
| 0x0001000F (65551) | VIDEO_ENCODER_INIT_DONE | 手机 → 车机 |
| **0x00020001 (131073)** | **VIDEO_DATA** | **手机 → 车机（H.264 裸流）** |
| 0x00020002 (131074) | HU_HEARTBEAT | 车机 → 手机 |
| 0x0001001B (65563) | MD_HEARTBEAT | 手机 → 车机 |
| 0x00010018 (65560) | MD_FOREGROUND | 手机 → 车机 |

完整表见 `refs/carlife_pc_tool/protocol/constants.py`

### 2.4 负载序列化

**Protocol Buffers**，包名 `com.baidu.carlife.protobuf`。
本项目需要定义的消息：

| 消息 | 字段 |
|---|---|
| `CarlifeProtocolVersion` | majorVersion(1,int32), minorVersion(2,int32) |
| `CarlifeProtocolVersionMatchStatus` | matchStatus(1,int32), carlifeProtocolVersion(2,int32) |
| `CarlifeDeviceInfo` | os, board, bootloader, brand, cpuAbi, cpuAbi2, device, display, fingerprint, hardware, host, cid, manufacturer, model, product, serial, codename, incremental, release, sdk, sdkInt, carlifeversion, btaddress |
| `CarlifeStatisticsInfo` | cuid, versionName, versionCode, channel, connectCount, connectSuccessCount, connectTime, crashCycle |
| `CarlifeAuthenResult` | authenResult(1,bool) |
| `CarlifeFeatureConfigList` | cnt, featureConfig(repeated), huBtAudioSupport, huBtName, huBtMAC |
| `CarlifeVideoEncoderInfo` | width(1), height(2), frameRate(3) |

完整定义见 `refs/carlife_pc_tool/protocol/proto_codec.py`

---

## 三、握手与推流时序

**车机为发起方**，手机端被动响应。原始状态机见 `refs/carlife_pc_tool/core/state_machine.py`。

```
车机                                手机端（本项目）
 │                                     │
 ├─[TCP 连 7240/8240/...]─────────────►│  监听 7 端口，接受连接
 │                                     │
 ├─ 98305 CarlifeProtocolVersion ─────►│  版本协商
 │  (majorVersion=4, minorVersion=0)   │
 │                                     │
 │◄──── 65538 MatchStatus ─────────────┤  matchStatus=1 表示匹配
 │                                     │
 ├─ 98343 CarlifeStatisticsInfo ──────►│  （车机发统计信息）
 ├─ 98307 HU_INFO (车机设备信息) ─────►│
 │                                     │
 │◄──── 65540 MD_INFO (手机设备信息) ──┤  ★ 需真实手机信息
 │                                     │
 │◄──── 65611 MD_AUTHEN_RESULT ────────┤  authenResult=true
 │                                     │
 ├─ 98380 HU_AUTHEN_RESULT ───────────►│
 ├─ 98311 HU_VIDEO_ENCODER_INIT ──────►│  ★ 车机告知期望分辨率/帧率
 │                                     │
 │◄──── 65544 VIDEO_ENCODER_INIT ──────┤  手机确认编码参数
 │                                     │
 ├─ 98313 VIDEO_ENCODER_START ────────►│  ★ 开始推流
 │                                     │
 │◄──── 131073 VIDEO_DATA (H.264) ─────┤  ★ 持续推送
 │                                     │
 ├─ 131074 HU_HEARTBEAT ──────────────►│  （车机心跳）
 │◄──── 65563 MD_HEARTBEAT ────────────┤  手机心跳，1s 周期
```

**关键点**：

1. **心跳周期 1000ms**（车机侧实现），源码 `sources/d/b/a/a/p/m/a/c.java:44-55`
2. **视频编码参数由车机决定**（98311 携带 width/height/frameRate），手机端必须按车机的期望值编码
3. 视频负载是 **H.264 裸流（NALU）**，无额外包头
4. 建立连接时机：**车机主动连**，手机端只需监听

---

## 四、鸿蒙侧实现映射

### 4.1 能力清单（**已用 SDK 声明文件与真实编译核实**）

| 需求 | 实现层 | 实际 API | 状态 |
|---|---|---|---|
| TCP 服务端（7 端口监听） | ArkTS | `@ohos.net.socket` → `constructTCPSocketServerInstance()` | ✅ 编译通过 |
| 报文封包/拆包 + PB 编解码 | ArkTS | 自研（无官方库） | ✅ 编译通过 + 字节级对拍通过 |
| 握手状态机 + 心跳 | ArkTS | 自研 | ✅ 编译通过 |
| **屏幕采集** | **Native C++** | `OH_AVScreenCapture_StartScreenCaptureWithSurface()` | ✅ 编译通过 |
| **H.264 硬编码** | **Native C++** | `OH_VideoEncoder_*` + `OH_VideoEncoder_GetSurface()` | ✅ 编译通过 |
| 采集→编码数据通路 | Native C++ | 采集输出直连编码器输入 Surface（**零拷贝**） | ✅ 编译通过 |
| 后台保活 | ArkTS | `backgroundTaskManager` + `AUDIO_RECORDING` 模式 | ✅ 编译通过 |
| 音频 | 不实现 | 走蓝牙 A2DP，App 不碰蓝牙 API | — |

#### ⚠️ 4.1.1 一个推翻原方案的关键发现（只有真编译能暴露）

原方案（本文件早期版本）把屏幕采集与 H.264 编码都放在 **ArkTS** 层，用的是
`@ohos.multimedia.avScreenCapture` 与 `media.createVideoEncoderByMimeType`。
**这两条路都不存在**：

| 原计划的 ArkTS API | 实际情况（SDK 全量检索） |
|---|---|
| `media.createVideoEncoderByMimeType()` / `media.VideoEncoder` | **ArkTS 侧完全没有视频编码 API**。编码只在 Native 层：`multimedia/player_framework/native_avcodec_videoencoder.h` |
| `media.createAVScreenCaptureRecorder()` | 存在，但配置结构 `AVScreenCaptureRecordConfig` 的 **`fd` 是必填项** —— 它是"录屏到文件"，**拿不到实时帧** |

**结论：采集与编码整条链路必须下沉到 C++。** 这不是性能优化，是唯一可行路径。

#### 4.1.2 Native 管线设计

```
OH_AVScreenCapture ──Surface──▶ OH_VideoEncoder ──H.264 NALU──▶ napi_threadsafe_function ──▶ ArkTS ──TCP──▶ 车机
```

- 采集输出**直连**编码器输入 Surface，画面不经 CPU 搬移
- 编码输出经 `napi_threadsafe_function` 投递到 JS 线程（编码回调在编解码器线程，不能直接调 JS）
- 帧队列有界（32 帧）；满时**丢帧并立即请求 I 帧**，而不是无限排队或阻塞编码器
- Profile 用 **Baseline**：无 B 帧、无 CABAC —— 安卓 4.4 老车机硬解最稳的组合
- 开 `OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY`，压低首帧与端到端延迟

#### 4.1.3 编码参数（对齐车机 98311 下发值）

| 参数 | 值 | 依据 |
|---|---|---|
| 分辨率 | 车机下发（默认 1280x720） | `CarlifeVideoEncoderInfo` |
| 帧率 | 车机下发（默认 30） | 同上 |
| 码率 | 按 `w*h*fps*0.1` 估算，夹在 1.5~20 Mbps | 经验值 |
| Profile | Baseline | 老车机兼容性 |
| 码率模式 | CBR | 无线链路下稳定 |
| I 帧间隔 | 2000 ms | 车机中途重连的等待上限 |
| 低延迟 | 开启 | 投屏场景对时延敏感 |

### 4.2 关键技术风险与对策

**风险 1：屏幕采集的用户授权（唯一无法绕过的点）**
- Native 采集同样会触发系统录屏授权弹窗，用户拒绝则启动失败（返回阶段号 9）
- 系统在采集期间有常驻提示 —— 这是系统强制行为
- **未核实**：是否支持长时持有会话、会不会定期重新弹窗。**只能真机实测**
- 对策：把阶段号回传到 UI，让用户看到"是授权被拒"而不是"启动失败"

**风险 2：ArkTS 无 Protobuf 运行时** → 已解决
- 自研编解码器，只覆盖 int32 / bool / string / repeated message 四种类型
- **已与 Google 官方 protobuf 库做字节级对拍：16/16 通过**

**风险 3：后台保活的任务类型（容易选错）**
- 长时任务类型**不能随便选**。`DATA_TRANSFER` 的官方用途是"上传下载"，且文档写明
  超过 10 分钟不更新进度会被系统取消 —— 对持续投屏是错的
- 正确选择：`BackgroundMode.AUDIO_RECORDING = 3`，官方用途描述明确写着
  "**recording and screen capture in the background**"
- 需要 `ohos.permission.KEEP_BACKGROUND_RUNNING`（已在 module.json5 声明）

**风险 4：编码性能与画质平衡**
- 高分辨率 @30fps 硬编需评估设备能力
- 对策：分辨率/帧率由车机下发，天然可降级；码率模式 CBR 便于预估带宽

**风险 5：导航画面裁切**
- 车机屏幕宽高比与手机不同（车机通常超宽）
- 对策：按车机下发的 `width/height` 编码；采集侧可用
  `OH_AVScreenCapture_SetCaptureArea` 做区域裁剪（本版本未启用）

---

## 五、工程结构（已落地）

```
E:/ZM/CarHi/harmony/
├── AppScope/app.json5
├── build-profile.json5                 工程配置（compatibleSdkVersion 26.0.0）
├── hvigorfile.ts                       构建入口
├── hvigor/hvigor-config.json5
├── oh-package.json5
└── entry/
    ├── build-profile.json5             含 externalNativeOptions（CMake）
    ├── hvigorfile.ts
    ├── oh-package.json5                依赖 libcarlifecodec.so
    └── src/main/
        ├── module.json5                权限声明
        ├── cpp/                        ── Native 采集编码（必须用 C++）
        │   ├── CMakeLists.txt
        │   ├── screen_encoder.h/.cpp   OH_AVScreenCapture + OH_VideoEncoder
        │   ├── napi_init.cpp           NAPI 桥接 + 线程安全回调
        │   └── types/libcarlifecodec/  类型声明（index.d.ts）
        └── ets/
            ├── protocol/               ── 协议层（字节级对拍已验证）
            │   ├── Constants.ets       62 个消息 ID + 7 通道端口
            │   ├── Framing.ets         报文封包/拆包 + 流式读取器
            │   ├── Protobuf.ets        自研 PB 编解码（varint/string/message）
            │   └── Messages.ets        12 个 CarLife 消息结构
            ├── transport/
            │   └── ChannelServer.ets   7 端口 TCP 服务端
            ├── core/
            │   ├── StateMachine.ets    握手状态机 + 心跳
            │   ├── NativeCodec.ets     桥接到 native 模块
            │   ├── BackgroundKeeper.ets 长时任务（AUDIO_RECORDING）
            │   └── CarLifeEngine.ets   链路编排
            ├── entryability/
            │   └── EntryAbility.ets    主 Ability
            └── pages/
                └── Index.ets           主界面
```

---

## 六、实施步骤

| 阶段 | 内容 | 验证方式 | 状态 |
|---|---|---|---|
| **P0** | 协议层：Constants / Framing / Protobuf / Messages | 与官方 protobuf 库字节级对拍 | **✅ 16/16 通过 + 编译通过** |
| **P1** | 传输层：7 端口 TCP 服务端 | 编译 + 真机对连 | **✅ 编译通过，待真机** |
| **P2** | 握手状态机 + 心跳 | 方向互补校验 + 编译 | **✅ 5/5 通过 + 编译通过** |
| **P3** | 采集 + H.264 编码（Native C++） | 编译 + 真机出画面 | **✅ 编译通过，待真机** |
| **P4** | 推流打通（131073 → 车机 8240） | `carlife_pc_tool` 解码看画面 | **✅ 代码完整，待真机** |
| **P5** | 真车机联调 | 需真实车机 | 待 P4 |

**验证策略**：`carlife_pc_tool` 是逆向自真实车机端的完整实现，**可作为联调对端**。
P0~P4 全部可以在没有真车机的情况下，用它验证到「协议正确 + 画面可解」。

### 已完成的验证证据（全部可复跑）

| 验证项 | 方法 | 结果 |
|---|---|---|
| **ArkTS 编译** | hvigorw assembleHap（Command Line Tools 26.0.0） | **✅ 0 错误** |
| **Native C++ 编译** | 同上（CMake + Ninja + clang，arm64-v8a） | **✅ 0 错误** |
| **HAP 打包** | 同上 | **✅ 产出 1.66 MB 未签名 HAP** |
| **签名链路** | 自建 CA 链跑 `sign-profile` + `sign-app` + `verify-app` | **✅ Verify success（证书链 3 级、权限签名通过）** |
| **构建可复现** | 清空 `build/`+`.cxx/` 后从零重建两次，逐条目比对 | **✅ 12/12 条目内容字节一致** |
| **Native 符号与依赖** | `llvm-nm` / `llvm-objdump` 检查产物 .so | **✅ 7 个库依赖齐全，OH_* API 调用真实存在** |
| 消息编码字节级正确 | 与 Google 官方 protobuf 库（Python）逐字节对拍 | **✅ 16/16 通过** |
| 握手方向互补 | 手机端发出的每条消息，车机端参考实现均有接收处理 | **✅ 5/5 通过** |
| 常量一致性 | ArkTS 的 62 个消息 ID + 8 个端口值 vs Python 参考实现 | **✅ 全部一致** |

**注意**：编译与构建已实测通过；**运行期行为（采集授权、编码出画、真机握手）尚未验证**，
需要鸿蒙真机 + 真实车机。这两者必须分开讲。

---

## 七、工程现状

代码已落地于 `E:/ZM/CarHi/harmony/`，**已实测编译通过并产出 HAP**。

### 7.1 构建方式（命令行，无需 DevEco Studio）

工具链：`Command Line Tools 26.0.0`（API 26 / HarmonyOS 26.0.0 Release）
装在 `E:/AITools/command-line-tools`。构建需要 **JDK**（打包步骤会 `spawn java`）。

```bash
export DEVECO_SDK_HOME="E:/AITools/command-line-tools/sdk"
export DEVECO_NODE_HOME="E:/AITools/command-line-tools/tool/node"
export NODE_HOME="E:/AITools/command-line-tools/tool/node"
export JAVA_HOME="C:/Users/dev/.jdks/jbr_dcevm-11.0.16"   # 任意 JDK 11+ 即可
export PATH="$JAVA_HOME/bin:$PATH"

cd E:/ZM/CarHi/harmony
"$DEVECO_NODE_HOME/node.exe" "E:/AITools/command-line-tools/hvigor/bin/hvigorw.js" assembleHap
```

产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`

一键脚本见 `tools/build.sh`。

### 7.1.1 签名（HAP 装进真机的必要条件）

未签名的 HAP **装不进真机**。构建日志里那句
`hvigor WARN: No signingConfig found for product default` 就是这个意思。

签名三件套：

| 文件 | 作用 | 来源 |
|---|---|---|
| `keystore.p12` | 私钥 + 证书链 | **本地生成**（`tools/sign.sh genkey`） |
| `*.cer` | 应用签名证书（三级-二级-根） | AGC 用 CSR 换取 |
| `*.p7b` | Profile（权限 + 设备白名单） | AGC 生成 |

流程：

```bash
bash tools/sign.sh genkey     # ① 生成 certs/keystore.p12 + certs/carhi.csr
# ② 手动：登录 AGC 上传 carhi.csr → 下载 .cer；建 Profile → 下载 .p7b
#    调试 Profile 需要先注册真机 UDID（hdc shell bm get --udid）
#    放到 certs/ 并命名为 carhi-debug.cer / carhi-debug.p7b（或 release 版）
bash tools/sign.sh            # ③ 签名
bash tools/sign.sh verify     # ④ 校验
bash tools/build.sh signed    # 或：构建 + 签名一步到位
```

配套工具：

| 命令 | 用途 |
|---|---|
| `bash tools/sign.sh status` | 看 `certs/` 现有材料、缺什么 |
| `bash tools/sign.sh inspect <p12> [密码]` | 检查一份 p12：别名、**自带证书链长度**、与已有 `.p7b` 内嵌证书**比对指纹** |
| `bash tools/sign.sh verify` | 校验已签名 HAP 的签名链与 Profile |
| `bash tools/bundle.sh` | 查看 / 切换 / 恢复 App 的 `bundleName`（复用旧 Profile 时才需要） |

**关键认知**：签名要**私钥（`.p12`）**、证书链（`.cer`）、Profile（`.p7b`）三样齐备。
其中 **Profile 只是"授权声明"，不含私钥** —— 这是最容易误解的一点。
丢了私钥就签不了名，没有替代路径。

复用旧证书的三条路线（详见 `certs/README.md`）：

| 路线 | 做法 | AGC 操作 | 风险 |
|---|---|---|---|
| **A（推荐）** | 保持自己的包名，AGC 只新建一个 Profile（可引用同一张证书 + 同一台设备） | 1 步 | 无 |
| **B** | `tools/bundle.sh` 改包名与旧 Profile 一致，直接用旧 `.p7b` | 0 步 | ⚠️ 同包名 + 同证书 = 判定为**升级**，会覆盖手机上那个应用 |
| **C** | 用本目录 `carhi.csr` 去 AGC 新建证书 + 新建 Profile | 2 步 | 无 |

详见 `certs/README.md`。

#### SDK 自带的 `OpenHarmony.p12` 用不了（已实测排除）

`E:/AITools/command-line-tools/sdk/default/openharmony/toolchains/lib/OpenHarmony.p12`
（密码 `123456`）看起来像"现成证书"，实测**不能用于 HarmonyOS 真机**：

- 库中 8 个别名里，`openharmony application release` 等应用证书是**自签的**
  （`issuer == subject`），并非由 `OpenHarmony Application CA` 签发。
  拼成三级-二级-根后必然报 `verify certificate chain failed! Signature does not match.`
- 唯一带 2 级链的非自签别名是 `openharmony application ca`，但它不是软件签名证书，
  签出来的包在 `verify-app` 阶段报
  `verify permission signature failed, msg: Wrong key usage`。

**结论：必须申请华为开发者证书，没有本地绕过路径。**

> 已做的验证：用自建 CA 链（root → 中间 CA → 应用证书）+ 自签 Profile
> 完整跑通了 `genkey → sign-profile → sign-app → verify-app` 全流程，
> 得到 `verify: Verify success`、`verify codesign success`、
> `verify permission sign success`、证书链 3 级、Profile 中 bundle 正确。
> 即**脚本链路本身已验证无 bug**，缺的只是华为签发的那两张文件。


### 7.2 编译过程中修掉的真实问题（不是猜的，是编译器报的）

| # | 问题 | 真相 |
|---|---|---|
| 1 | `ohos.permission.GET_BLUETOOTH_INFO` 不是合法权限 | 本方案音频走系统 A2DP，App 不碰蓝牙 API，该权限**直接删除**（而非换成 `ACCESS_BLUETOOTH`） |
| 2 | `socket.TCPSocketServerListenOptions` 不存在 | 正确写法是 `srv.listen(address: NetAddress)`，且 `NetAddress` 需含 `family` |
| 3 | `TCPSocketConnection` 没有 `read()` / `setExtraOptions()` | 收数据用 `on('message', ...)` 事件；`setExtraOptions` 在 **server** 上设 |
| 4 | `media.createVideoEncoderByMimeType` 不存在 | ArkTS 侧根本没有视频编码 API → 整体下沉 C++ |
| 5 | ArkTS 的屏幕采集只能录到文件 | `AVScreenCaptureRecordConfig.fd` 必填 → 同样下沉 C++ |
| 6 | `backgroundTaskManager.startBackgroundRunning` 返回 `void` 而非 taskId | 且任务类型应选 `AUDIO_RECORDING`（用途含 screen capture），不是 `DATA_TRANSFER` |
| 7 | `OH_AVSCREEN_CAPTURE_ErrCode` ≠ `OH_AVErrCode` | 两个是不同类型，成功常量分别是 `AV_SCREEN_CAPTURE_ERR_OK` / `AV_ERR_OK`，必须分开声明变量 |
| 8 | native 模块用默认导入会退化成 `any` | 触发 `arkts-no-any-unknown`，须改用**具名导入** |
| 9 | `wantAgent.WantAgent` 不存在 | `WantAgent` 是 `@kit.AbilityKit` 的**独立导出**，不是 `wantAgent` 命名空间成员 |
| 10 | `@Builder` 不接受 `content: () => void` 形式的 lambda 参数 | 改用 `@Component` + `@BuilderParam` + 尾随闭包 |

### 7.3 协议层验证工具（本机可运行，与鸿蒙工具链无关）

```bash
# 1. 生成 Python 基准字节（需 .venv-verify）
./.venv-verify/Scripts/python.exe tools/gen_expected.py > tools/expected.json

# 2. 协议层字节级对拍
node tools/verify.mjs

# 3. 握手方向校验
node tools/verify_handshake.mjs

# 4. 静态一致性检查（常量/引用）
node tools/static_check.mjs
```

### 7.4 尚未验证的部分（诚实标注）

| 项 | 为什么没验 | 怎么验 |
|---|---|---|
| 屏幕采集授权行为（能否长时持有会话） | 需真机 | 真机跑，看是否反复弹窗 |
| 编码出画 | 需真机 | 用 `carlife_pc_tool` 连手机，解码看画面 |
| 真车机握手 | 需真实车机 | 车机连手机，看状态机走到 `98313` |
| 音频走蓝牙的实际效果 | 需真机 + 车机 | 系统蓝牙配对后听 |
| 安卓 4.4 车机的实际流畅度 | 需真实车机 | 硬件天花板，无法软件预估 |

---

## 八、目标设备与 SDK 版本

**测试真机：HUAWEI nova 14 Ultra（型号代码 `MRT-AL10`），运行 HarmonyOS 7.0。**

### 版本号体系（已核对华为官方文档）

**HarmonyOS 7.0 = API 26 = `26.0.0`**，三者指同一代次。

| 系统版本 | API | 发布 |
|---|---|---|
| HarmonyOS 5.0.0 | 12 | 2024-10 |
| HarmonyOS 6.0.0 | 20 | 2025-09 |
| 6.0.1 / 6.0.2 | 21 / 22 | 2025-11 / 2026-01 |
| 6.1.0 / 6.1.1 | 23 / 24 | 2026-04 / 2026-05 |
| **HarmonyOS 7.0** | **26** | 2026-08（正式发布） |

> ⚠️ **重要变化**：从 API 26 起，版本号改用**语义化格式 `X.Y.Z`**，
> 不再写 `X.Y.Z(N)`。所以是 `"26.0.0"`，**不是** `"26.0.0(26)"`。
> 这也是 `"5.0.0(12)"` 那种写法在新工程里会显得突兀的原因。

本机 Command Line Tools 是 **26.0.0**，与目标设备同代次，无需额外下载 SDK。

### 工程配置（已对齐）

`harmony/build-profile.json5` 的 `products[0]`：

```json5
"compatibleSdkVersion": "26.0.0",
"compileSdkVersion":    "26.0.0",
"targetSdkVersion":     "26.0.0",
"runtimeOS":            "HarmonyOS"
```

另有 `oh-package.json5` 与 `hvigor/hvigor-config.json5` 的 `modelVersion`
一并从 `5.0.0` 升到 `26.0.0`。

**为什么三个版本都设 26**：目标设备只有 nova 14 Ultra 一台，跑 HarmonyOS 7.0。
原先设 `compatibleSdkVersion: "5.0.0(12)"` 会造成两个实际问题：

- `Circle().fill()`（`Index.ets:137`）是 **API 26** 才有的 API
- `srv.close()`（`ChannelServer.ets:186`）是 **API 20** 才有的 API

编译器会报 `API is supported since SDK version 26.0.0. However, the current
compatible SDK version is 5.0.0(12)`，提示需要 `apiAvailable` 兜底。
声明与实际一致后，这两条警告消失。

**产物中已写入**（`module.json`，可从 HAP 内直接读出）：

| 字段 | 值 |
|---|---|
| `minAPIVersion` | `260000026` |
| `targetAPIVersion` | `260000026` |
| `apiReleaseType` | `Release` |

### 若将来要下放到老设备

把 `compatibleSdkVersion` 调回目标系统对应的 API 即可（如 6.1.1 用 `"6.1.1(24)"`），
但届时必须给上面两个 API 加 `canIUse` / `apiAvailable` 判断，否则同样会报警告。
`compileSdkVersion` 保持 26.0.0 不用动。

### 仍未确认

1. **真车机的 CarLife 版本号** —— 协议版本号（当前按 4.0.0 实现，需核对）
2. **真机验证采集授权行为** —— 是否支持长时持有会话、会不会定期重新弹窗
3. **是否需要 App 内发起蓝牙配对** —— 当前依赖用户在系统设置里自行配对


---

## 九、明确不做的事（及原因）

| 项 | 原因 |
|---|---|
| 触控回传（车机操作手机） | 需求收窄时排除。技术上需 `AccessibilityExtensionAbility`，有授权摩擦 |
| CarLife 音频通道（Ch3/4/5） | 音频走蓝牙 A2DP 独立通道，零开发量 |
| 后台导航模式（`MD_NAVI_NEXT_TURN_INFO`） | 需要车机端有地图引擎渲染导航，安卓 4.4 老车机不具备；且数据源需自研导航 |
| 复用第三方导航 App 数据 | 鸿蒙无公开 API 读取其他 App 状态；无障碍读屏不可靠且地图 App 升级即失效 |
| 在 ArkTS 里做采集/编码 | 该层根本没有视频编码 API，采集也只能录到文件（见 4.1.1） |
| 采集区域裁剪 / 车机比例适配 | `OH_AVScreenCapture_SetCaptureArea` 可用，但需先确认车机实际期望的比例再启用 |

---

## 十、参考材料

| 材料 | 路径/来源 | 价值 |
|---|---|---|
| `carlife_pc_tool` | `E:/ZM/CarHi/refs/carlife_pc_tool/` | **协议真值源**，逆向自真实车机端，含完整状态机 |
| `apollo-DuerOS` | Gitee `gilyang/apollo-DuerOS` | 百度官方开源车机端（GitHub 已删，需登录 Gitee） |
| `CarLifeWirelessBox` | GitHub `pitate7777777/CarLifeWirelessBox` | 无线连接协议分析报告 |

