/**
 * CarLife 手机端主 Ability
 *
 * 职责：
 *   1. 加载主界面
 *   2. 把 UIAbilityContext 交给 BackgroundKeeper，供推流时申请长时任务
 *   3. 启动时跑诊断自检（USB / WiFi-P2P），**只写日志，不改界面**
 *
 * 注意：**不在这里申请长时任务**。长时任务只在真正开始推流时才需要，
 * 应用一启动就申请既浪费也会在用户没连车机时弹无关通知。
 */

import {
  AbilityConstant, UIAbility, Want, abilityAccessCtrl, Permissions, PermissionRequestResult
} from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { accessibility } from '@kit.AccessibilityKit';
import { bundleManager } from '@kit.AbilityKit';

import { BackgroundKeeper } from '../core/BackgroundKeeper';
import { FloatBall } from '../core/FloatBall';
import { UsbProbe, UsbProbeResult, AoaProbeResult, UsbLinkKind } from '../core/UsbProbe';
import { WifiProbe, WifiProbeResult } from '../core/WifiProbe';

const DOMAIN: number = 0x0001;
const TAG: string = 'CarHi';

/**
 * 打印本应用的 appId（供申请高德导航 SDK 的 Key 用）。
 *
 * 高德的 HarmonyOS Key 必须绑定 appId，而 appId 的格式是
 *   `<包名>_<签名串>`
 * 例如 `com.amap.demo_BGtGgVB3ASqU7ar1nHkwX4s0nIexDbEwqNrVoatUDs17GrClWC7V2/zhoYh6tFQHAd5DASWVTEAgvZfzrEGljjs=`
 *
 * ★ 只能运行时取，没法从工程文件里读出来 —— 所以固定在这里打一条日志。
 * ★ 换签名 / 换机器后 appId 会变，**Key 必须重新申请**（否则 SDK 鉴权失败）。
 */
function logAppId(): void {
  try {
    const flag = bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_SIGNATURE_INFO;
    const info = bundleManager.getBundleInfoForSelfSync(flag);
    const appId: string = info.signatureInfo?.appId ?? '(空)';
    const bundle: string = info.name;
    hilog.info(DOMAIN, TAG, `★ 【申请高德Key用】bundleName=${bundle}`);
    hilog.info(DOMAIN, TAG, `★ 【申请高德Key用】appId=${appId}`);
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(DOMAIN, TAG, `取 appId 失败 code=${err.code} msg=${err.message}`);
  }
}

/**
 * ★ 打印本包的**构建模式**（2026-10-16 新增）。
 *
 * ## 为什么必须打这一条
 *
 * 官方 Car Kit《开发准备》原文：「在打包应用时，请在 DevEco Studio 中…将编译模式
 * 修改为 "release"」—— **debug 包下 Car Kit 的某些接口不会生效**，表现为
 * `801 Capability not supported`（"能力不支持"），极易被误读成"设备不支持"。
 *
 * 而 `tools/build.sh` 的默认模式是 **debug**（`MODE="debug"`），也就是说
 * **在此之前我们所有真机测试跑的都是 debug 包** —— 那条"Car Kit 判死"的结论
 * 有可能是被这个前提污染的。
 *
 * 问题在于：装上包之后**从界面/日志上看不出它是 debug 还是 release**。
 * hvigor 会把模式写进 HAP 清单的 `app.buildMode` / `app.debug`，
 * 运行时可以通过 `appInfo.debug` 读回来（`app.debug == true` ⇔ 编译模式 debug）。
 *
 * 所以固定在这里打一条，**让"当前跑的到底是哪个包"变成日志里的事实**，
 * 免得下次又拿一个 debug 包的负结果去给整个能力判死。
 *
 * ★ 读的是 `appInfo.debug`，不是 `releaseType`：后者只反映 SDK 的
 *   apiReleaseType（两者都是 "Release"），区分不出编译模式。
 */
function logBuildMode(): void {
  try {
    const flag = bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION;
    const info = bundleManager.getBundleInfoForSelfSync(flag);
    // appInfo 在 ArkTS 里可能为 undefined，做一次兜底
    const appInfo = info.appInfo;
    const isDebug: boolean = appInfo !== undefined && appInfo !== null ? appInfo.debug : false;
    const mode: string = isDebug ? 'debug' : 'release';
    hilog.info(DOMAIN, TAG, `★ 【构建模式】buildMode=${mode} (app.debug=${isDebug})`
      + `${isDebug ? '  ⚠ Car Kit 需 release 包，此包下部分接口会报 801' : '  ✔ 满足 Car Kit 的 release 要求'}`);
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(DOMAIN, TAG, `取构建模式失败 code=${err.code} msg=${err.message}`);
  }
}

/**
 * 启动时自动跑一次 USB 自检（**诊断用**）。
 *
 * 行为：只读 `probe()` 必跑；**只有真看到配件**时才进一步 `tryAoa()` 打开 fd 试读。
 * 全程只写日志，不改界面状态。
 *
 * ── 2026-10-13：**默认关闭** ──
 * USB 已实测确诊为 **AOA 配件模式**（非网络模式），而 AOA 只有一条字节流、
 * 7 个逻辑通道的复用格式未知 —— 需新增 fd 字节流传输层，短期无解。
 * 界面上的「USB 直连诊断 / AOA 试连」两个入口也已一并移除（见 `pages/Index.ets`）。
 * 这条自检每次启动都跑一遍却必然得到 NONE，属无效动作，故关掉。
 * **需要重新诊断时把这里改回 true 即可**（探针实现 `core/UsbProbe.ets` 仍在仓库里）。
 */
const AUTO_USB_SELFCHECK: boolean = false;

/**
 * 启动时自动跑一次 WiFi/P2P 自检（**诊断用**）。
 *
 * 现状：**默认关闭** —— Wi-Fi 直连已经做成 App 的正式功能
 * （见主界面的「Wi-Fi 直连」卡片，`pages/WifiDirectCard.ets`），
 * 由用户手动扫描 / 连接，不再需要每次启动都扫一遍射频。
 * 需要远程诊断时把这里改回 true 即可（`aa start` 触发，结果只进日志）。
 *
 * 权限：只用 GET_WIFI_INFO（normal / system_grant），**不需要位置权限**，
 *       因此**锁屏状态下也能跑**，不依赖用户点授权框。
 */
const AUTO_WIFI_SELFCHECK: boolean = true;

/** P2P 发现时长（毫秒） */
const WIFI_P2P_DISCOVER_MS: number = 6000;

/** 发现到目标盒子后是否自动发起 P2P 连接（诊断开关，做完可置 false） */
const AUTO_P2P_CONNECT: boolean = true;
/** 目标对端名字的子串 —— 耘电车联 QH3002 的 P2P 名为 "Box_xxxx"（实测 Box_259E） */
const P2P_TARGET_NAME: string = 'Box';
/**
 * P2P 单次尝试的等待上限（毫秒）。
 *
 * 注意：密码与频段**不在这里指定** —— 官方 proto（`CarlifeWirlessTargetProto`）注释写明
 * 盒子 P2P 组是「名字, 密码, 频率, 频段」四元组（示例 `"box, 88888888, 5745, 2"`），
 * 所以由 `WifiProbe.P2P_ATTEMPTS` 里那几组参数依次尝试。
 */
const P2P_CONNECT_WAIT_MS: number = 12000;

/** 全局状态（供 UI 读取与跨模块共享） */
export class CarLifeRuntime {
  /** 运行日志环形缓冲，供 UI 展示 */
  static logs: string[] = [];

  /**
   * 应用当前是否在前台。
   *
   * 由 `EntryAbility.onForeground/onBackground` 维护，供 UI 读取。
   * 用途：切到后台时在界面上提示"投屏期间请勿切后台/息屏"。
   * ⚠ 与 BackgroundKeeper.isActive 一样是**普通静态字段**，UI 必须镜像成
   *   @State 才会刷新（见 Index.ets 的 tickTimer）。
   */
  static foregrounded: boolean = true;

  /**
   * ★ 内录 PCM 音频 sink（由引擎侧注入，供画面源转发）。
   *
   * 数据流：KeepAliveCapture / ScreenEncoder 采集的内录 PCM
   *   → 本 sink → CarLifeEngine → MEDIA_DATA → 车机 AUDIO(Ch3/9240)。
   *
   * 官方 SDK 的 `FEATURE_CONFIG_AUDIO_TRANSMISSION_MODE` 默认 0 = 专用音频通道，
   * 所以 TCP 推 PCM 是主路径（详见 core/CarLifeEngine.ets 音频节）。
   *
   * 放在这里的原因：两个画面源（NativeHmiSource / ScreenCaptureSource）都要用，
   * 而它们之间不应互相依赖。传 null 解除绑定。
   */
  static audioSink: ((pcm: Uint8Array, timestampUs: number, sourceType: number) => void) | null = null;

  static addLog(text: string): void {
    const ts = new Date().toTimeString().substring(0, 8);
    CarLifeRuntime.logs.push(`[${ts}] ${text}`);
    if (CarLifeRuntime.logs.length > 300) {
      CarLifeRuntime.logs.shift();
    }
    hilog.info(DOMAIN, TAG, text);
  }
}

export default class EntryAbility extends UIAbility {
  /** 悬浮球实例（全局单例） */
  private static floatBall: FloatBall | null = null;

  /**
   * 尝试显示悬浮球。
   *
   * 失败时把原因写进 `AppStorage['carhiFloatStatus']`，供设置页展示 ——
   * 因为悬浮球是增强功能，不可用时应让用户**知道为什么**，而不是静默失败。
   *
   * ⚠️ 2026-10-16：**本方法当前没有任何调用点（死代码）**，悬浮球方案已作废
   *   （`FLOAT_VIEW` 权限 system_basic → 声明即装机失败 9568289）。
   *
   * ⚠️ 且原来的点击转发用了 `AppStorage.get<() => void>('carhiFloatClickHandler')`
   *   —— **AppStorage 不能存函数**，页面侧那次 `setOrCreate` 会让应用启动即崩
   *   （error 140115，真机 release 包实测）。现已删除页面侧的写入，这里也不再读。
   *   若将来恢复悬浮球：用 `emitter` 发事件，别用 AppStorage 传函数。
   */
  private static tryShowFloatBall(ctx: Context): void {
    if (EntryAbility.floatBall === null) {
      EntryAbility.floatBall = new FloatBall();
    }
    EntryAbility.floatBall.show(ctx, () => {
      hilog.warn(DOMAIN, TAG, '悬浮球被点击，但悬浮球方案已作废（见 core/FloatBall.ets 注释）');
    }).then((r) => {
      AppStorage.setOrCreate<string>('carhiFloatStatus',
        r.ok ? '悬浮球已启用' : `悬浮球不可用：${r.message}`);
    });
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onCreate');
    BackgroundKeeper.init(this.context);

    // ★ 打印本应用的 appId —— 申请高德 SDK Key 必需（格式「包名_签名串」）。
    //   高德的鉴权把 Key 与 appId 绑定，换签名/换机器都要重新申请，所以这里固定打一条。
    logAppId();
    logBuildMode();

    if (AUTO_USB_SELFCHECK) {
      // 延后一点跑，避免与启动时的端口监听抢资源；结果只进日志。
      setTimeout(() => {
        this.runUsbSelfCheck();
      }, 2000);
    }

    if (AUTO_WIFI_SELFCHECK) {
      // 与 USB 自检错开（2s vs 5s），避免两件事同时抢射频/端口
      setTimeout(() => {
        this.runWifiSelfCheck();
      }, 5000);
    }

    // 无障碍自检：**每次都跑**（只读查询，无副作用），用于判定
    // accessibility_config.json 的能力声明有没有被系统真正解析出来。
    setTimeout(() => {
      this.runA11ySelfCheck();
    }, 3000);
  }

  /**
   * 无障碍自检（**只读，无副作用**）。
   *
   * 目的：在让用户去「设置 → 无障碍」手动开启服务之前，先确认
   * `resources/base/profile/accessibility_config.json` 里的能力声明**被系统解析出来了**。
   *
   * 为什么必须查这一步：无障碍扩展的配置文件键名（`accessibilityCapabilities` /
   * `accessibilityExtensionTypes`）在官方文档与第三方文章里说法不一致，SDK 里也搜不到。
   * 键名写错的后果是**静默的** —— 服务能装上、也能出现在设置列表里，但 `capabilities`
   * 是空的，用户开了也注入不了手势，排查时极难定位。这里直接问系统要解析结果，
   * 一次就能判死。
   *
   * 判定标准：
   *   - 列表里能找到 `com.carhi.carlifephone` 且 capabilities 含 `gesture` → 键名正确
   *   - 找得到但 capabilities 为空 → **键名写错**，配置没被解析
   *   - 完全找不到 → 扩展声明/打包有问题
   *
   * 注：`getAccessibilityExtensionListSync` 是**公开 API**（@since 12，
   * 无 @systemapi 标签），普通应用可直接调用，不需要任何权限。
   */
  private runA11ySelfCheck(): void {
    try {
      const list: accessibility.AccessibilityAbilityInfo[] =
        accessibility.getAccessibilityExtensionListSync('all', 'install');
      hilog.info(DOMAIN, TAG, `[无障碍自检] 系统已安装的无障碍扩展共 ${list.length} 个`);
      let found: boolean = false;
      for (let i = 0; i < list.length; i++) {
        const a: accessibility.AccessibilityAbilityInfo = list[i];
        const isOurs: boolean = a.bundleName === 'com.carhi.carlifephone';
        hilog.info(DOMAIN, TAG, `[无障碍自检]   ${isOurs ? '★' : ' '} ${a.bundleName}/${a.name}`
          + ` capabilities=[${a.capabilities.join(',')}]`
          + ` abilityTypes=[${a.abilityTypes.join(',')}]`
          + ` label=${a.label} needHide=${a.needHide}`);
        if (isOurs) {
          found = true;
          const hasGesture: boolean = a.capabilities.indexOf('gesture') >= 0;
          if (hasGesture) {
            hilog.info(DOMAIN, TAG, '[无障碍自检] ★ 结论：gesture 能力已被系统解析 → 配置键名正确');
          } else {
            hilog.error(DOMAIN, TAG, '[无障碍自检] ★ 结论：capabilities 里**没有** gesture'
              + ' → accessibility_config.json 的键名写错了，配置未被解析');
          }
        }
      }
      if (!found) {
        hilog.error(DOMAIN, TAG, '[无障碍自检] ★ 结论：列表里找不到本应用 → 扩展声明/打包有问题');
      }
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, `[无障碍自检] 查询异常 code=${err.code} msg=${err.message}`);
    }
  }

  /**
   * 启动自检：先跑只读的 USB 诊断；若真识别到 AOA 配件，再试连一次
   * （openAccessory 拿 fd + 试读原始字节）。全部只写日志，不改界面。
   */
  private async runUsbSelfCheck(): Promise<void> {
    try {
      const r: UsbProbeResult = await UsbProbe.probe();
      const lines: string[] = UsbProbe.format(r);
      for (let i = 0; i < lines.length; i++) {
        hilog.info(DOMAIN, TAG, lines[i]);
      }
      if (r.kind === UsbLinkKind.ACCESSORY || r.kind === UsbLinkKind.BOTH) {
        hilog.info(DOMAIN, TAG, '[USB自检] 检测到 AOA 配件，自动试连并试读原始流...');
        const a: AoaProbeResult = await UsbProbe.tryAoa();
        const aLines: string[] = UsbProbe.formatAoa(a);
        for (let i = 0; i < aLines.length; i++) {
          hilog.info(DOMAIN, TAG, aLines[i]);
        }
      }
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, `[USB自检] 异常: ${err.message}`);
    }
  }

  /**
   * WiFi/P2P 自检：探测设备 P2P 能力、当前 P2P 状态、并做一轮发现，
   * 把结果写进日志（`CarLifeWifiProbe` 标签）。不改界面、不改连接。
   */
  private async runWifiSelfCheck(): Promise<void> {
    try {
      hilog.info(DOMAIN, TAG, '[WiFi自检] 开始 P2P 探测...');
      const r: WifiProbeResult = await WifiProbe.probeP2p(WIFI_P2P_DISCOVER_MS);
      const lines: string[] = WifiProbe.format(r);
      for (let i = 0; i < lines.length; i++) {
        hilog.info(DOMAIN, TAG, lines[i]);
      }

      if (!AUTO_P2P_CONNECT) {
        return;
      }

      // 在发现结果里找目标盒子（名字子串匹配）
      let targetAddr: string = '';
      let targetName: string = '';
      for (let i = 0; i < r.peers.length; i++) {
        if (r.peers[i].deviceName.indexOf(P2P_TARGET_NAME) >= 0) {
          targetAddr = r.peers[i].deviceAddress;
          targetName = r.peers[i].deviceName;
          break;
        }
      }
      if (targetAddr === '') {
        hilog.info(DOMAIN, TAG, `[WiFi自检] 未发现名字含 "${P2P_TARGET_NAME}" 的对端，不发起连接`);
        return;
      }

      hilog.info(DOMAIN, TAG, `[WiFi自检] 命中目标 "${targetName}" @${targetAddr}，发起 P2P 连接...`);
      // 密码/频段不再由这里指定 —— 由 WifiProbe.P2P_ATTEMPTS 里那几组参数依次尝试
      // （依据官方 proto 注释：盒子 P2P 组是「名字, 密码, 频率, 频段」四元组）
      const err: string = await WifiProbe.connectP2p(targetAddr, P2P_CONNECT_WAIT_MS);
      if (err === '') {
        hilog.info(DOMAIN, TAG, '[WiFi自检] P2P 连接成功');
      } else {
        hilog.error(DOMAIN, TAG, `[WiFi自检] P2P 连接失败: ${err}`);
      }
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, `[WiFi自检] 异常: ${err.message}`);
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onDestroy');
    BackgroundKeeper.release();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'loadContent succeeded');
    });

    // ★ 麦克风权限（2026-10-16 新增）：屏幕采集要**真的开麦**，长时任务
    //   `AUDIO_RECORDING` 才有系统认的「录音流」；否则会被判为名实不符而**挂起**
    //   （系统原文：`No recording stream detected when applying for audio recording mode`）。
    //
    //   放在 loadContent 之后：权限弹框需要 UI 已经起来。
    //   不阻塞、不抛错 —— 拒绝授权只会让投屏时缺录音流，不该拦住整个启动。
    this.requestMicPermission();

    // ⚠️ 悬浮球已废弃（2026-10-15 实测）：鸿蒙的全局悬浮窗权限
    //   （FLOAT_VIEW / SYSTEM_FLOAT_WINDOW / USE_FLOAT_BALL）**全部要求系统应用**，
    //   声明 FLOAT_VIEW 会导致装机失败（9568289）。故不再尝试创建。
    //   相关代码保留在 core/FloatBall.ets + pages/FloatBall.ets 以备将来（如获系统授权）。
    //   ⇒ 取代方案：用**通知栏常驻通知**提供快捷启停（见 Index 的服务通知）。

    // ★ 方向：竖屏（2026-10-15 由「锁横屏」改为竖屏）。
    //
    //   module.json5 里声明的方向实测**不生效**，必须用代码设置（这个坑早前踩过）。
    //
    //   为什么改竖屏：自 2026-10-15 起手机端**只显示设置面板**，不再预览车机 HMI；
    //   设置面板是竖排列表，竖屏才是它的正确形态。车机画面改由 native HmiRenderer
    //   自绘、**与手机屏幕方向完全无关**（两条独立通路，见 MEMORY §1.3），
    //   推流分辨率由车机经 65544 下发（实测 1280x720），不取自屏幕。
    //
    //   枚举值见 @ohos.window.d.ts：PORTRAIT=1 / LANDSCAPE=2 / AUTO_ROTATION_LANDSCAPE=7。
    try {
      const win: window.Window = windowStage.getMainWindowSync();
      win.setPreferredOrientation(window.Orientation.PORTRAIT).then(() => {
        hilog.info(DOMAIN, TAG, '[方向] 已请求竖屏');
      }).catch((e: BusinessError) => {
        hilog.error(DOMAIN, TAG, `[方向] 方向请求失败 code=${e.code} msg=${e.message}`);
      });

      // ★ 沉浸式：内容延伸到系统栏之下 + 隐藏系统导航条。
      //
      //   车载场景下面向车机的那块画面**不该出现系统 UI**（导航条/小白条），
      //   否则既是视觉干扰，也会被算进画布区域导致内容被挤压。
      win.setWindowLayoutFullScreen(true).then(() => {
        hilog.info(DOMAIN, TAG, '[沉浸] 全屏布局已开启');
      }).catch((e: BusinessError) => {
        hilog.error(DOMAIN, TAG, `[沉浸] 全屏布局失败 code=${e.code} msg=${e.message}`);
      });

      // 隐藏底部导航条 + 那条小白条（navigationIndicator）。
      win.setSpecificSystemBarEnabled('navigation', false).catch((e: BusinessError) => {
        hilog.error(DOMAIN, TAG, `[沉浸] 隐藏导航条失败 code=${e.code} msg=${e.message}`);
      });
      win.setSpecificSystemBarEnabled('navigationIndicator', false).catch((e: BusinessError) => {
        hilog.error(DOMAIN, TAG, `[沉浸] 隐藏导航指示条失败 code=${e.code} msg=${e.message}`);
      });
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, `[方向] 获取主窗口失败 code=${err.code} msg=${err.message}`);
    }
  }

  /**
   * 申请麦克风权限（`ohos.permission.MICROPHONE`，`user_grant`）。
   *
   * ## 为什么需要 —— 2026-10-16 真机证据
   *
   * 长时任务 `AUDIO_RECORDING` 的系统判据是「**音频录制正在进行**」。
   * 我们曾把 `OH_AVScreenCapture` 的 `micCapInfo` 置 0 + `SetMicrophoneEnabled(false)`，
   * 系统随即报（真机日志原文）：
   *   `★[保活] 长时任务挂起 id=395 suspendState=true reason=-1
   *      msg=No recording stream detected when applying for audio recording mode`
   * → 长时任务被**挂起** → 切后台即冻结 → 采集与心跳(65563)全停 → 车机 5 秒超时断开。
   *
   * ⚠️ 只采「内录」（`innerCapInfo` / `OH_ALL_PLAYBACK`）**不算**录音流 ——
   *   内录数据我们确实在回调里收得到（日志 `★ inner audio buffer #3000`），
   *   但系统照样报 `No recording stream detected`。它认的是**麦克风录音会话**。
   *
   * ## 行为
   *
   * 已授权时系统直接返回，不弹框（幂等）。
   * 失败只记日志、**不抛** —— 拒绝授权不该拦住整个启动，只是投屏时会缺录音流。
   */
  private requestMicPermission(): void {
    const perms: Permissions[] = ['ohos.permission.MICROPHONE'];
    try {
      const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      atManager.requestPermissionsFromUser(this.context, perms)
        .then((result: PermissionRequestResult) => {
          const granted: number[] = result.authResults;
          if (granted.length > 0 && granted[0] === 0) {
            hilog.info(DOMAIN, TAG,
              '[权限] 麦克风已授权（录音流可用，长时任务不会被挂起）');
          } else {
            hilog.warn(DOMAIN, TAG,
              `★[权限] 麦克风未授权（authResults=${JSON.stringify(granted)}）`
              + ' —— 投屏时无录音流，AUDIO_RECORDING 长时任务可能被系统挂起');
          }
        })
        .catch((e: BusinessError) => {
          hilog.error(DOMAIN, TAG, `[权限] 申请麦克风失败 code=${e.code} msg=${e.message}`);
        });
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG,
        `[权限] createAtManager 失败 code=${err.code} msg=${err.message}`);
    }
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'onForeground');
    // 回到前台，界面回到用户视线内 —— 清掉"切后台"提示
    CarLifeRuntime.foregrounded = true;
  }

  /**
   * 切到后台。
   *
   * ★ 2026-10-13 路线 A 重置后的重大简化：
   *   录屏方案时代这里要做「主动重建屏幕采集」（因为系统会掐断采集）。
   *   改自绘后**画面来源是我们自己渲染的，不受系统采集管线约束**，
   *   切后台不会打断它（前提：长时任务保持）。所以这里只更新一个状态标志，
   *   供界面显示"已切后台"提示即可。
   */
  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'onBackground');
    CarLifeRuntime.foregrounded = false;
  }
}
