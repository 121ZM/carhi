/**
 * 独立投屏窗口（CastWindow）—— 专门承载"要投给车机的那块画面"。
 *
 * ## 为什么要单独开一个窗口
 *
 * 大哥的诉求：**主窗口保留设置页，投屏画面放到另一个窗口里**。
 *
 * 走不通的两条路：
 *   - ❌ 把主窗口自己缩小：`window.resize()` / `moveWindowTo()` 官方语义是
 *     **只在 `WindowStatusType.FLOATING` 下生效**，主窗口全屏时调用直接报 1300002。
 *   - ❌ 旧接口 `window.createWindow(TYPE_FLOAT)`：要求 `SYSTEM_FLOAT_WINDOW`，
 *     声明后装机直接失败 9568289（见 `EntryAbility.ets` 的实测注释）。
 *
 * ✅ 本页同时服务两种窗口（由 `Index.openCastWindow()` 决定）：
 *   ① 系统悬浮窗 `@ohos.window.floatView`（API 26）：能浮在其他 App 之上，
 *      但 `start()` 需要 `FLOAT_VIEW`，普通签名证书无 ACL，须先在 AGC 申请；
 *   ② 应用子窗口 `WindowStage.createSubWindowWithOptions()`：不需要任何权限，
 *      `SubWindowOptions.windowRect` 能在创建时**直接指定位置和尺寸**，一次成型 16:9。
 *
 * ## 16:9 的意义
 *
 * 采集区域与车机画布（1280×720）宽高比一致 ⇒ **不变形、无黑边**，
 * 不必再纠结 `StrategyForFillMode` 的 ASPECT_SCALE_FIT / SCALE_TO_FILL。
 *
 * ## ⚠ 已知边界（不是 bug）
 *
 * 子窗口仍属于本应用。**切到其他 App 时整个应用不可见**，此时区域采集
 * 录到的是"别的内容盖在这块区域上"的画面。要真正"浮在微信之上"，
 * 必须走系统悬浮窗（`FLOAT_VIEW` 在 AGC 申请到 ACL 后自动生效）。
 */

import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MapPage } from './MapPage';

const DOMAIN: number = 0x0001;
const TAG: string = 'CarHi';

@Entry
@Component
struct CastWindow {
  aboutToAppear(): void {
    hilog.info(DOMAIN, TAG, '[投屏窗口] 已创建');
  }

  aboutToDisappear(): void {
    hilog.info(DOMAIN, TAG, '[投屏窗口] 已销毁');
  }

  /** 关闭自己（由地图页的「返回」触发） */
  private closeSelf(): void {
    window.getLastWindow(getContext(this)).then((w: window.Window) => {
      w.destroyWindow().catch((e: Error) => {
        hilog.error(DOMAIN, TAG, `[投屏窗口] 销毁失败: ${e.message}`);
      });
    }).catch((e: Error) => {
      hilog.error(DOMAIN, TAG, `[投屏窗口] 取窗口失败: ${e.message}`);
    });
  }

  build() {
    Column() {
      // 地图铺满整个子窗口。
      // MapPage 的 onExit / onToggleCast 都有默认空实现，这里显式传 onExit
      // 以便用户在地图页点「返回」时直接关掉这个投屏窗口。
      MapPage({
        onExit: (): void => {
          this.closeSelf();
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
  }
}
