/**
 * CarHi 无障碍扩展 —— **触控注入可行性探针**（最小版）
 *
 * 目的（单一、明确）：
 *   验证 `AccessibilityExtensionContext.injectGestureSync()` 在 **API 26 / HarmonyOS 7.0** 上
 *   是否仍然可用。SDK 里它标了 `@deprecated since 12` 且**未给 `@useinstead`** ——
 *   deprecated ≠ removed，但必须真机实测才能定论。
 *
 * 为什么不用官方 `inputEventClient`：
 *   那条路的权限 `ohos.permission.CONTROL_DEVICE` 是 `grantMode = manual_settings`
 *   （声明即装机失败 `9568289`）且 `deviceTypes = ["2in1"]`（手机上调用回 `801`）。
 *   无障碍是第三方应用**唯一**可用的注入通道（用户在「设置 → 无障碍」手动开启即可，不需系统签名）。
 *
 * 旁证：2026-10-13 用 `accessibility.getAccessibilityExtensionListSync()` 读到本机 7 个无障碍扩展，
 *   其中 `com.huawei.hmos.cardistributedassist`（华为「车机互联」）声明了
 *   `capabilities=[retrieve, keyEventObserver, gesture]`，`com.huawei.hmos.hicar` 里更是有一个
 *   直接叫 `SimulateClickAccessibilityAbility` 的扩展 —— 说明**官方自己的车机触控回注就是走这条路**。
 *
 * 本探针**不做**跨进程对接、不接 CarLife 协议 —— 只在服务连上后注入**一次**硬编码坐标的点击，
 * 并把调用结果（成功 / 错误码）打进日志。验证通过再谈接协议。
 *
 * 日志：走 `hilog`（domain 0x0001 / tag `CarHiA11y`），在设备上形如
 *   `A00001/com.carhi.carlifephone/CarHiA11y: ...`
 *   不用 `console.info` —— 后者落点 tag 不确定，排查时容易抓不到。
 *   抓取姿势：`hdc shell "nohup timeout 30 hilog > /data/local/tmp/x.log 2>&1 &"`。
 */

import { AccessibilityExtensionAbility, AccessibilityEvent, GesturePath, GesturePoint } from '@kit.AccessibilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'CarHiA11y';

/**
 * 探针点击坐标（px）。
 *
 * ★ 刻意落在**状态栏**里（屏幕 1272×2860，取正上方中央）。
 * 原因：鸿蒙的状态栏**对单击是惰性的**（必须下滑才会拉出通知栏/控制中心），
 * 所以这一下落在桌面、设置页、还是 CarHi 自己的界面上，都**不会误触任何控件**。
 * 早期版本取的是屏幕正中 (640,1500)，那在桌面上极可能正好是一个 App 图标 —— 会误启动应用。
 */
const PROBE_X: number = 636;
const PROBE_Y: number = 60;

/** 服务连上后延迟多久注入（ms）。留足时间让用户从「设置」切回 CarHi。 */
const PROBE_DELAY_MS: number = 20000;

export default class CarHiAccessibilityExtAbility extends AccessibilityExtensionAbility {
  private injected: boolean = false;

  onConnect(): void {
    hilog.info(DOMAIN, TAG, '无障碍服务已连接（CarHi 触控注入探针）');
    hilog.info(DOMAIN, TAG, `${PROBE_DELAY_MS / 1000}s 后将在状态栏 (${PROBE_X},${PROBE_Y})`
      + ` 注入一次点击 —— 该位置对单击惰性，不会误触控件`);
    // 只探一次，避免反复注入干扰；断开重连会重置（见 onDisconnect）
    if (this.injected) {
      return;
    }
    this.injected = true;
    setTimeout(() => {
      this.probeInjectGesture();
    }, PROBE_DELAY_MS);
  }

  onDisconnect(): void {
    hilog.info(DOMAIN, TAG, '无障碍服务已断开');
    // 重置：用户把服务关掉再开，可以再探一次（否则第二次连上会被 injected 挡住）
    this.injected = false;
  }

  onAccessibilityEvent(event: AccessibilityEvent): void {
    // 探针不需要事件流，留空即可（避免刷屏把日志冲掉）
  }

  /** ★ 核心探针：注入一次点击，只看调用是否抛异常 */
  private probeInjectGesture(): void {
    hilog.info(DOMAIN, TAG, '开始调用 injectGestureSync ...');
    try {
      const path: GesturePath = new GesturePath(100);
      const p: GesturePoint = new GesturePoint(PROBE_X, PROBE_Y);
      path.points = [p, p];
      this.context.injectGestureSync(path);
      hilog.info(DOMAIN, TAG, '★ 结果：injectGestureSync 正常返回，未抛异常 → API 在 API 26 上仍然存活');
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, `★ 结果：injectGestureSync 抛异常 code=${err.code} msg=${err.message}`);
      if (err.code === 9300003) {
        hilog.error(DOMAIN, TAG, 'code 9300003 = 无无障碍权限，说明服务未真正启用');
      } else if (err.code === 401) {
        hilog.error(DOMAIN, TAG, 'code 401 = 参数错误（可能是 GesturePath/GesturePoint 构造方式已变）');
      }
    }
  }
}
