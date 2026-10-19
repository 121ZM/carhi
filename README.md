# autoCar · 鸿蒙版 CarLife 手机端

在 **HarmonyOS NEXT** 上实现百度 CarLife **手机端**，向真实 CarLife 车机推送手机整屏画面。

> **适用场景**：车机是安卓 4.4 这类老旧系统，跑不动高德车机版 —— 用这台手机负责渲染，车机只当"显示器"。
>
> **换机器继续开发？** 先读 **[HANDOFF.md](HANDOFF.md)** —— 里面有当前进度、已确认结论、待办清单与编译命令。

---

## 范围

| 做 | 不做 |
|---|---|
| 屏幕采集 → H.264 编码 → 推流到车机 | 触控回传（车机操作手机） |
| 车机主动连接后的握手与信令应答 | TTS / VR 语音通道（Ch4 / Ch5） |
| 七个端口的 TCP 服务端监听 | 后台导航信息模式（需车机有地图引擎） |
| 音频通道 Ch3（TCP 9240，PCM S16LE） | — |

---

## 关键设计：手机端是 TCP **服务端**

```
车机 (客户端)  ──主动连接──▶  手机 (服务端, 监听中)
```

手机在 `7240 / 8240 / 9240 / 9241 / 9242 / 9340 / 9440` 七个端口监听，车机主动来连，
**监听地址为 `0.0.0.0`（所有网卡）**，因此无论连接来自 WiFi 还是 USB 虚拟网卡都能接收。

**这条"车机主动连手机"的结论同时适用于 WiFi 与 USB** —— 两种承载下角色一致，
差异只在底层网络如何建立。详见 [HANDOFF.md](HANDOFF.md) 第四节。

| 通道 | 端口 | 用途 | 是否实现 |
|---|---|---|---|
| 1 CMD | 7240 | 控制/信令 | ✅ 必须 |
| 2 VIDEO | 8240 | H.264 视频流 | ✅ 必须 |
| 3 AUDIO | 9240 | 媒体音频 PCM | ✅ 已实现（S16LE） |
| 4 TTS | 9241 | 导航语音 PCM | ⛔ 未实现 |
| 5 VR | 9242 | 语音识别 | ⛔ |
| 6 TOUCH | 9340 | 触控/按键 | 仅监听，不处理 |
| 7 DATA | 9440 | 车况传感器 | 仅监听，不处理 |

另有 **UDP 7999**：车端监听，手机广播发现（无线连接入口）。

---

## 技术要点

### 采集 + 编码必须在 Native C++

ArkTS 侧**没有视频编码 API**，且 `AVScreenCaptureRecorder` 只能录到文件（`config.fd` 必填，无法拿到裸流）。因此整条管线下沉到 C++：

```
OH_AVScreenCapture_StartScreenCaptureWithSurface()   ← 采集，输出到 Surface
        │  零拷贝
        ▼
OH_VideoEncoder (Surface 模式)                        ← H.264 硬编
        │
        ▼
napi_threadsafe_function                             ← 投递回 JS 线程
        │
        ▼
TCP VIDEO 通道 (8240) 发送裸流 (Annex-B NALU)
```

### 协议层

全大端序。Ch1/6 用 8 字节头，其他通道用 12 字节头，负载为 Protobuf（自研精简编解码，只覆盖 int32 / bool / string / repeated message）。

协议实现以 [`MeshHun/carlife_pc_tool`](https://github.com/MeshHun/carlife_pc_tool)（逆向自真实车机端）为真值源，做了字节级对拍。

### 后台保活

长时任务类型选 `BackgroundMode.AUDIO_RECORDING`（官方用途包含 "recording and screen capture in the background"）。

> ⚠️ 不是 `DATA_TRANSFER` —— 那是上传下载场景，10 分钟不更新进度会被系统取消。

---

## 工程结构

```
CarHi/
├── HANDOFF.md                  当前进度 / 结论 / 待办 / 编译与签名命令（换机器先看这个）
├── STREAMING.md                推流通路说明（画面源 / 音频通道 / 投屏窗口 / 权限边界）
├── PLAN.md                     技术方案全文（协议规格、设计决策、坑位记录）
├── harmony/                    鸿蒙工程
│   ├── AppScope/app.json5      bundleName: com.carhi.carlifephone
│   └── entry/src/main/
│       ├── cpp/                screen_encoder（采集+硬编）/ hmi_renderer（自绘 HMI）
│       │                       canvas_encoder / keepalive_capture / napi_init
│       └── ets/
│           ├── core/           CarLifeEngine / StateMachine / CaptureGate / UsbProbe
│           │                   NativeHmiSource / ScreenCaptureSource / CanvasFrameSource
│           │                   AmapNaviBridge / AmapIconMapper / WifiProbe
│           ├── protocol/       Constants / Framing / Protobuf / Messages
│           ├── transport/      ChannelServer（7 端口 TCP 服务端）
│           ├── accessibility/  无障碍扩展（读导航信息，可选）
│           └── pages/          Index / MapPage / AmapNaviPage / CastWindow / FloatBall
├── design/nav-hmi/             自绘 HMI 的设计稿与真机截图
├── tools/                      构建 / 签名 / 验证脚本
└── certs/                      签名材料（私钥不入库，见 certs/README.md）
```

---

## 构建

依赖 [Command Line Tools](https://developer.huawei.com/consumer/cn/download/)（含 SDK 与 hvigor），并需要一个 JDK（11+）。

```bash
bash tools/build.sh            # 增量构建
bash tools/build.sh clean      # 清空产物从零构建
bash tools/build.sh release    # release 模式
bash tools/build.sh signed     # 构建 + 签名（需先备好 certs/ 里的证书）
```

> ⚠️ **首次构建前先装三方依赖**（高德 SDK 是 5 个字节码 HAR，`oh_modules/` 不进仓库）：
> `ohpm install --all`；且 `build-profile.json5` 的
> `app.products[0].buildOption.strictMode.useNormalizedOHMUrl` 必须为 `true`。
> 细节见 [HANDOFF.md](HANDOFF.md) 6.6。

工具链不在默认位置时用环境变量覆盖：

```bash
CLT_HOME=/path/to/command-line-tools \
JAVA_HOME=/path/to/jdk \
bash tools/build.sh
```

产物：`harmony/entry/build/default/outputs/default/entry-default-unsigned.hap`

### 版本号约定

目标设备为 **HarmonyOS 7.0 = API 26 = 26.0.0**（同一代次的三个名字）。

> 🔴 自 API 26 起版本号改用**语义化格式 `X.Y.Z`**，不再写 `X.Y.Z(N)`。
> 即配置里写 `"26.0.0"`，**不是** `"26.0.0(26)"`。

---

## 签名

HAP 必须签名才能装进真机。需要三件套：`.p12`（私钥）+ `.cer`（证书）+ `.p7b`（Profile）。

```bash
bash tools/sign.sh genkey          # ① 生成 keystore.p12 + carhi.csr
# ② 手动：登录 AGC 上传 carhi.csr → 下载 .cer；建调试 Profile → 下载 .p7b
bash tools/sign.sh sign            # ③ 签名
bash tools/sign.sh verify          # ④ 校验
bash tools/sign.sh inspect <p12>   # 检查一份密钥库能否复用
bash tools/sign.sh status          # 查看当前材料齐备情况
```

> ⚠️ **SDK 自带的 `OpenHarmony.p12` 签不了真机包** —— 里面的应用证书是自签的，拼链必报
> `Signature does not match`。必须申请华为开发者证书，无本地绕过。
>
> 密码经环境变量传入，不写入脚本：
> `CARHI_KEY_PWD='...' bash tools/sign.sh sign`

详见 [`certs/README.md`](certs/README.md)。

---

## 验证

协议层改动后必须重跑对拍：

```bash
node tools/verify.mjs            # 与官方 protobuf 库字节级对拍
node tools/verify_handshake.mjs  # 握手方向互补校验
node tools/static_check.mjs      # 常量/引用一致性
```

## 当前状态

> 进度与待办以 [HANDOFF.md](HANDOFF.md) 为准；各推流通路的细节见 [STREAMING.md](STREAMING.md)。
> 当前代码对应远端提交 `c0b9bdf`（2026-10-18）。

| 项 | 状态 |
|---|---|
| 协议逆向核实 | ✅ 字节级对拍通过 |
| 传输层 / 状态机 | ✅ 方向校验通过（含 65609 鉴权修复） |
| WiFi 直连推流 | ✅ **真机验证通过**，长时间稳定 |
| 画面通路 | ✅ 自绘 HMI / 整屏采集 / 独立投屏窗口 / 高德真地图 |
| 系统小窗接管投屏 | ⏳ 代码完成，待真机验证拖拽入口 |
| 音频通道 Ch3 | ✅ 已实现（实测见 `STREAMING.md` 3.4） |
| ArkTS / C++ 编译 | ✅ 0 错误（本机 re-verified） |
| HAP 打包 | ✅ 签名成功（调试证书，hdc 安装） |
| USB 直连 | ⏳ 诊断模块就绪，待实测 |
| 无线盒子 QH3002 | ⏸ 未开始 |

> **编译通过 ≠ 能跑。** 未装机验证的行为都不算完成。

---

## 参考

- 协议真值源：[MeshHun/carlife_pc_tool](https://github.com/MeshHun/carlife_pc_tool)（逆向自真实车机端，含完整状态机与消息 ID）
  本仓库不包含其源码，需要时自行 clone 到 `refs/carlife_pc_tool`。
