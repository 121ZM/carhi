# 推流能力说明（画面源 / 音频通道 / 投屏窗口）

> 用途：说明**车机能看到什么、由谁产生、怎么切换**，以及每条的权限边界与未验证项。
> 配套：`HANDOFF.md`（协议与掉线排查史）、`PLAN.md`（整体方案）。
> 最后更新：2026-10-18

---

## 一、总览

车机端只有一块 1280×720 的"显示器"。往这块屏上送内容有 **三条互斥的画面通路**，
外加 **一条独立的音频通道**。三条画面通路**共用同一个硬件编码器**，
所以切换必须走完整 `stop → start`，不能热替换。

| 能力 | 界面入口 | 实现 | 真机验证 |
|---|---|---|---|
| 自绘 HMI（CarWith 卡片） | 默认 | `core/NativeHmiSource.ets` + `cpp/hmi_renderer.cpp` | ✅ 已出图 |
| 整屏采集 | `📱 应用投屏（录屏推车机）` | `core/ScreenCaptureSource.ets` + `cpp/screen_encoder.cpp` | ✅ 已出图 |
| 系统小窗（智慧多窗）+ 区域采集 | 系统手势拖成小窗，无需按钮 | `Index.enterFloatMode()` + `SetCaptureArea` | ⏳ 仅编译验证 |
| 独立投屏窗口 + 区域采集 | `🪟 独立投屏窗口（主窗口不变）` | `pages/CastWindow.ets` + `SetCaptureArea` | ⏳ 仅编译验证 |
| 音频（PCM → 9240） | 无（自动） | `core/CarLifeEngine.ets` + `cpp/keepalive_capture.cpp` | ✅ 协议层实测通过 |

---

## 二、画面通路

### 2.1 自绘 HMI（NativeHmiSource）

native 侧用 `OH_Drawing` 自绘车机画面（导航卡、状态栏），直接渲染进编码器输入 Surface。
**手机屏幕上不显示这张图**，它与 ArkUI 页面是两条完全独立的通路。

- 唯一耦合点：`EngineHolder.pushHmi()`（数据推给 native 渲染器）
- 兜底：`startFallbackPush()` 截图推送，**只在 `frameSource.isFallback === true` 时运行**

### 2.2 整屏采集（应用投屏）

`OH_AVScreenCapture` 采集真实屏幕 → 编码器 → 车机。
能录到手机上的**任何 App**（高德、音乐播放器等）。

- 首次会弹**系统录屏授权框**，无法绕过（`core/CaptureGate.ets` 把重试压到系统下限）
- 采集画布跟随旋转：`SetCanvasRotation(true)` + `StrategyForCanvasFollowRotation(true)`
- 竖屏内容投到 16:9 车机会被拉伸（`StrategyForFillMode` 目前走系统默认）

### 2.3 系统小窗（智慧多窗）—— 不需要任何权限的"边用手机边投屏"（主推）

**思路**：应用自己不开窗，由用户用系统「智慧多窗」把 CarHi 拖成悬浮小窗；
应用检测到 `WindowStatusType.FLOATING` 后自动接管，只把这扇小窗推给车机。

前提（`module.json5`，**缺了用户根本拖不出小窗**）：

```json5
"supportWindowMode": ["fullscreen", "split", "floating"],
"preferMultiWindowOrientation": "landscape",
```

接管流程（`Index.startRegionWatch()` → `enterFloatMode()`）：

1. 界面切成**纯地图 16:9**（`build()` 的 `floatMode` 分支）。
   地图页必须传 `chrome: false` —— 顶部「返回设置 / 投屏到车机」按钮
   否则会一起被采集进车机画面
2. `setPreferredOrientation(LANDSCAPE)` + `resize(16:9)`
   （`resize()` 只在 FLOATING 下生效，全屏调用报 1300002）
3. `SetCaptureArea` 锁到该窗口矩形；拖动/缩放由 `windowRectChange` 实时跟随
4. 拖回全屏 → `exitFloatMode()`：恢复竖屏、撤区域、回设置页

两个实现细节：

- `windowStatusChange` 监听**在 `aboutToAppear` 里无条件注册**。系统手势随时可能发生，
  监听晚一步就完全没反应；启动时还会用 `getWindowStatus()` 补查一次
  （应用可能**以悬浮窗身份被拉起**，那种情况不会触发状态变化事件）
- 进入小窗时 `showAmapNavi` / `showRealMap` 会被临时卸载 ——
  高德地图实例只能有一个，两套同时渲染会互相打架

### 2.4 独立投屏窗口 + 区域采集（应用自建窗口）

**思路**：主窗口保留设置页，另开一个 16:9 窗口专门投屏，采集只取这块区域。

两级实现，前者失败自动降级：

| 级别 | 接口 | 能否浮在其他 App 之上 | 权限 |
|---|---|---|---|
| ① 系统悬浮窗 | `@ohos.window.floatView`（API 26） | ✅ | `FLOAT_VIEW`（`system_basic`，见 §四） |
| ② 应用子窗口 | `WindowStage.createSubWindowWithOptions()` | ❌ 切走即不可见 | 无 |

关键实现点：

- **16:9 是刻意选的**：区域宽高比与车机画布 1280×720 一致 ⇒ **不变形、无黑边**，
  不必再纠结 `StrategyForFillMode` 的 `ASPECT_SCALE_FIT` / `SCALE_TO_FILL` 取舍
- 尺寸基准用**屏幕短边**（`Math.min(width, height)`）。`setPreferredOrientation` 之后
  `display` 的宽高可能已按横屏互换，直接用 `d.width` 会算出超出屏幕高度的"小窗"
- `SubWindowOptions.windowRect` 在**创建时**一次成型，不依赖 `resize()`
  （`resize()` / `moveWindowTo()` 官方语义是**只在 `FLOATING` 下生效**，全屏主窗口调用报 1300002）
- 悬浮窗用 `onRectChange` 跟随拖动；子窗口用 `windowRectChange` 跟随
- **坑（已修）**：`RestartCapture()` 会重建采集实例，区域设置随之丢失。
  `StartCaptureLocked()` 末尾已加自动恢复，否则一次采集重启就会静默退回整屏

native 接口（`cpp/screen_encoder.h`）：

```cpp
int32_t SetCaptureArea(int32_t x, int32_t y, int32_t width, int32_t height);
int32_t ClearCaptureArea();
```

底层走 `OH_AVScreenCapture_SetCaptureArea(capture, displayId, &OH_Rect)`（API 20+），
采集前/采集中都能调；失败时沿用上次区域。区域由采集器在**送 Surface 之前**裁好，
所以 surface 直通模式不需要改成 buffer 模式再做软件裁剪。

### 2.5 真地图页

| 页面 | 用途 | 渲染方式 |
|---|---|---|
| `pages/MapPage.ets` | 高德 `MapViewComponent` 真地图（含路况图层、演示路线） | 高德 SDK 渲染 |
| `pages/AmapNaviPage.ets` | 高德导航引擎 + 截图喂编码器 | 高德 SDK 渲染 → `feedAmapFrame()` |
| `pages/CastWindow.ets` | 独立投屏窗口/悬浮窗的内容载体，内部只放 `MapPage` | 同上 |

`MapPage` 是普通 `@Component`（不是 `@Entry`），由宿主页条件渲染挂载；
`CastWindow` 是 `@Entry`，因为要被 `loadContent('pages/CastWindow')` / `setUIContext()` 加载。

---

## 三、音频通道（Ch3 / TCP 9240）

### 3.1 消息 ID（官方两来源核实）

| 常量 | 值 | 说明 |
|---|---|---|
| `MSG_MEDIA_INIT` | 196609 (0x30001) | 音频参数协商 |
| `MSG_MEDIA_STOP` | 196610 (0x30002) | 停止 |
| `MSG_MEDIA_PAUSE` | 196611 | 暂停 |
| `MSG_MEDIA_RESUME_PLAY` | 196612 | 恢复 |
| `MSG_MEDIA_SEEK_TO` | 196613 | 跳转 |
| `MSG_MEDIA_DATA` | **196614** (0x30006) | PCM 数据帧 |

> ⚠️ **历史 bug（已修）**：`MSG_MEDIA_DATA` 与 `MSG_MEDIA_STOP` 曾写反，
> 车机会把 PCM 当 STOP 解析。核实依据：车机端 `CommonParams.java`
> 与 `CTranRecvPackageProcess.h` 两个独立官方来源。

### 3.2 参数与编码

`MEDIA_INIT` 体为 `CarlifeMusicInit { sampleRate=1, channelConfig=2, sampleFormat=3 }`，
实际发 `48000 / 2ch / 16bit`。HU 侧映射：`channelConfig 1=mono 2=stereo`，
`sampleFormat 8=PCM_8BIT 16=PCM_16BIT`；解析失败时 HU 回落到 44100/2/16。

PCM 为 **S16LE 交织**，单帧上限按 HU 侧 `MEDIA_DATA_SIZE=100KB` 保守取 **48KB 分片**。

### 3.3 数据来源

音频不额外申请麦克风，走 **`OH_AVScreenCapture` 内录（inner audio）**：
`cpp/keepalive_capture.cpp` 开一路"只有音频、无视频、无麦克风"的采集会话，
既拿到 App 播放的声音，又让 `AUDIO_RECORDING` 长时任务保持有效。

链路：`keepalive_capture` PCM 回调 → `CarLifeRuntime.audioSink` →
`CarLifeEngine.sendAudioFrame()` → AUDIO(9240)。

- 只转发 `sourceType === 1`（内录）；麦克风源丢弃，避免把环境音推给车机
- AUDIO 通道重连后自动补发 `MEDIA_INIT`（`onChannelConnected`）
- `stopStreaming()` 先发 `MEDIA_STOP` 再停采集

### 3.4 实测结论（MRT-AL10）

- `MEDIA_INIT` 先于所有 DATA 到达，字段 `48000/2/16`
- 单帧恒定 **3840B**，50fps ⇒ `3840 ÷ 0.02 = 192000 B/s = 48000×2ch×2B`
  ⇒ **S16LE 位深坐实**（不再是假设）
- 15 秒收到 500 帧 = 1.92MB，`mock_hu.py` 回归 **35 项全过**

---

## 四、系统能力与权限边界（结论，避免重复踩坑）

| 结论 | 依据 |
|---|---|
| `floatView.create()` **不需要**权限；`start()` 需要 `FLOAT_VIEW`；`bind()` 另需 `USE_FLOAT_BALL` | `@ohos.window.floatView.d.ts` 方法级 `@permission` 标注 |
| `FLOAT_VIEW` = `user_grant` + **`system_basic`** ⇒ 普通签名证书无对应 ACL，**写进 `module.json5` 即装机失败 9568289** | `PermissionDefinitions.json` + 2026-10-15 实测 |
| 要启用悬浮窗：AGC 申请受限权限 → 审核通过 → 重签带 ACL 的 profile → 加一条 `requestPermissions`。**代码无需再改**，`openFloatWindow()` 自动生效 | — |
| 画中画（PiP）**不能**用来投地图 | `PiPConfiguration.componentController: XComponentController` 必填，只能承载 XComponent；且 `PiPWindowInfo` 只有 `{windowId,size}`，无屏幕坐标，无法喂 `SetCaptureArea` |
| 主窗口自己缩小成小窗做不到 | `resize()` / `moveWindowTo()` 仅 `WindowStatusType.FLOATING` 生效，否则 1300002 |
| 应用**无法请求**把自己变成悬浮窗 | `@ohos.window` 里没有 `setWindowMode` 类接口；`getWindowStatus()` 只读；`setSupportedWindowModes()` 只声明"允许哪些模式"、不切换。手机的"小窗"由系统智慧多窗/应用助手把整个窗口切成 FLOATING |
| 视频类 App 的小窗走的是 PiP | 内容天然是 Surface，满足 `componentController: XComponentController`；模板只有 `VIDEO_*` |
| 应用级采集（只录某个 App）**尚未实现** | `SetPickerMode(OH_CAPTURE_PICKER_MODE_APP_ONLY)` + `PresentPicker()`，API 26 可用 |
| 无法强制被采集 App 横屏 | 没有任何跨应用方向控制 API；只能用户把手机横过来，让高德自己切车载横屏 |

---

## 五、使用步骤

1. 打开 CarHi（服务默认自动启动，状态栏显示"已监听全部端口"）
2. 车机/盒子发起连接，握手完成后开始推流
3. 选画面源：
   - **默认** → 自绘 HMI（CarWith 导航卡）
   - **整屏** → 点「📱 应用投屏（录屏推车机）」，首次授权录屏
   - **系统小窗（推荐）** → 用系统「智慧多窗」把本应用拖成悬浮小窗。
     应用自动切成 16:9 纯地图、把采集区域锁到这扇小窗；手机其余部分照常用别的 App。
     拖回全屏即恢复设置页与整屏采集
   - **应用自建窗口** → 点「🪟 独立投屏窗口」，车机只显示这个 16:9 窗口；
     有 `FLOAT_VIEW` 时为可浮动的系统悬浮窗，没有则降级为应用子窗口（切到别的 App 会不可见）
4. 音频自动跟随：手机上有声音时，内录 PCM 自动进 9240；无播放则无帧（正常）

---

## 六、已知限制与待验证

**待真机验证**（本轮改动只过了编译）：

- ① **声明 `supportWindowMode` 后系统是否真的提供小窗入口**（这是整条路径的前提）
- ② 区域采集在 surface 直通模式下是否真的只出那一块
- ③ `windowRect` 与采集坐标系（DPI / 旋转）是否同一口径
- ④ 拖动/缩放窗口时区域能否实时跟随
- ⑤ `setPreferredOrientation(LANDSCAPE)` 在悬浮窗里的实际布局效果
- ⑥ 系统悬浮窗路径（需 `FLOAT_VIEW` 获批后才能跑）

**已知限制**：

- 应用**自己不能**把主窗口变成悬浮窗：SDK 里没有 `setWindowMode` 之类的接口，
  `getWindowStatus()` 只读、`resize/moveWindowTo` 只在已处于 FLOATING 时生效。
  所以小窗必须由用户用系统手势拖出来（这也是视频走 PiP、游戏靠系统窗口管理的原因）
- 应用子窗口属于本应用，**切到其他 App 时整个应用不可见**，此时区域采集录到的是
  "盖在这块区域上的别的内容"。要真正浮在别人之上必须走系统悬浮窗权限
- 竖屏内容投 16:9 车机会拉伸（整屏采集路径），应用级采集实现时再引入
  `StrategyForFillMode(ASPECT_SCALE_FIT)`
- `toggleRegionOnly()` 目前**没有 UI 入口**（系统拖拽已自动接管），保留备用
- `MapPageCompileProbe.ets` 是早期为了让 `MapPage` 进入编译的探针，
  `MapPage` 已接入 `CastWindow` 与 `Index`，该探针可删除

---

## 七、本轮涉及文件

```
harmony/entry/src/main/ets/
├── core/
│   ├── CarLifeEngine.ets       改：音频通道 startAudioStream/sendAudioFrame/stopAudioStream
│   ├── NativeHmiSource.ets     改：keepalive 音频采集启停 + PCM 转发
│   ├── ScreenCaptureSource.ets 改：setCaptureArea/clearCaptureArea 封装 + 重启后恢复
│   ├── NaviInfoProbe.ets       改：导航数据桥接
│   └── ...
├── pages/
│   ├── Index.ets               改：系统小窗自动接管（enterFloatMode/exitFloatMode）、
│   │                              独立投屏窗口、悬浮窗降级、区域跟随
│   ├── CastWindow.ets          新增：投屏窗口内容载体
│   ├── MapPage.ets             新增：高德 MapView 真地图（`chrome=false` 出纯地图）
│   └── MapPageCompileProbe.ets 新增：编译探针（可删）
├── protocol/Constants.ets      改：MEDIA_* 六个消息 ID（修正 DATA/STOP 写反）
└── transport/ChannelServer.ets 改：isAudioReady

harmony/entry/src/main/module.json5
                                改：supportWindowMode [fullscreen,split,floating]
                                    + preferMultiWindowOrientation landscape

harmony/entry/src/main/cpp/
├── keepalive_capture.{h,cpp}   新增：纯音频采集（长时任务保活 + 内录 PCM）
├── screen_encoder.{h,cpp}      改：SetCaptureArea/ClearCaptureArea + 重启后自动恢复
├── napi_init.cpp               改：区域采集与音频采集的 NAPI 导出
└── types/libcarlifecodec/index.d.ts  改：对应 TS 声明

tools/
├── mock_hu.py                  改：MEDIA_INIT/DATA/STOP 校验、存活快照式判定
└── hdct.sh                     新增：hdc tconn+exec 包装（治两调用间掉线）
```
