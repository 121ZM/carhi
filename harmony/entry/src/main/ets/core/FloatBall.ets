/**
 * 悬浮球（全局悬浮窗）—— 随时启动/停止投屏
 *
 * ## 目的
 *
 * 大哥的诉求：开车时不想"回到 autoCar 点按钮"，而是**随时点一下就开/关投屏**。
 * 所以做一个常驻屏幕的悬浮球。
 *
 * ## ★ 权限现实（必须先说清，这是本模块最大的不确定性）
 *
 * 鸿蒙的悬浮窗相关权限（SDK `PermissionDefinitions.json` 实证）：
 * | 权限 | grantMode | availableLevel | 能否用 |
 * |---|---|---|---|
 * | `SYSTEM_FLOAT_WINDOW` | system_grant | system_basic | ❌ 系统直接授予 |
 * | `USE_FLOAT_BALL`      | system_grant | system_basic | ❌ 同上 |
 * | **`FLOAT_VIEW`**      | **user_grant** | system_basic | ⚠️ **唯一可能有戏** |
 *
 * `FLOAT_VIEW` 是 `since 26.0.0` 的新权限，`grantMode = user_grant`
 * （用户授权弹框，**不是系统签名**）。但它的 `availableLevel` 仍是
 * `system_basic` —— **普通应用能否真正生效，必须以真机实测为准**。
 *
 * 所以本模块的设计原则：
 *   1. **创建失败不是崩溃** —— 优雅降级，只在日志里说明，不影响主流程；
 *   2. **提供明确的状态文案** —— 让用户知道"悬浮球没起来"以及原因；
 *   3. 失败时提示**备选方案**（用系统自带悬浮球 / 通知栏快捷方式）。
 *
 * ## 窗口类型
 * `window.WindowType.TYPE_FLOAT = 8`（全局悬浮窗，@StageModelOnly，@since 9）
 * ⚠️ `TYPE_SYSTEM_ALERT = 1` **已废弃**（deprecated since 11），不要用。
 */

import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'CarHiFloat';

/** 悬浮球创建结果 */
export interface FloatBallResult {
  ok: boolean;
  /** 失败原因（空串 = 成功） */
  message: string;
}

/**
 * 悬浮球管理器。
 *
 * 用法（在 UIAbility 的 onWindowStageCreate 之后）：
 *   const ball = new FloatBall();
 *   const r = await ball.show(ctx, onToggle);
 *   if (!r.ok) { 提示用户 r.message }
 */
export class FloatBall {
  private win: window.Window | null = null;
  private showing: boolean = false;

  get isShowing(): boolean {
    return this.showing;
  }

  /**
   * 创建并显示悬浮球。
   *
   * @param ctx 上下文（UIAbilityContext，用于 loadContent）
   * @param onToggle 点击回调（切换投屏开关）
   * @returns 结果；失败时 `message` 说明原因
   *
   * ⚠ 需要 `ohos.permission.FLOAT_VIEW`（已在 module.json5 声明）。
   *   若权限未授予或系统不支持，这里会返回失败而**不会抛异常**
   *   —— 悬浮球是增强功能，不该拖垮主流程。
   */
  async show(ctx: Context, onToggle: () => void): Promise<FloatBallResult> {
    if (this.showing) {
      return { ok: true, message: '' };
    }

    try {
      // ---- 1) 创建 TYPE_FLOAT 窗口 ----
      const config: window.Configuration = {
        name: 'carhi_float_ball',
        windowType: window.WindowType.TYPE_FLOAT,
        ctx: ctx
      };
      this.win = await window.createWindow(config);
      hilog.info(DOMAIN, TAG, 'TYPE_FLOAT 窗口创建成功');

      // ---- 2) 加载悬浮球 UI ----
      // 用独立的 pages 文件（main_pages.json 之外），避免影响主页面栈。
      await this.win.loadContent('pages/FloatBall');
      hilog.info(DOMAIN, TAG, '悬浮球 UI 已加载');

      // ---- 3) 定位到屏幕一角（避开状态栏与常规操作区）----
      //   ⚠ 不同 API 版本取"可用区域"的方式不同；这里先只做尺寸设置，
      //     位置由窗口系统按 TYPE_FLOAT 语义自行摆放，避免因取值为空而失败。
      try {
        await this.win.resize(120, 120);
      } catch (e) {
        // 尺寸设置失败不影响显示
        hilog.warn(DOMAIN, TAG, '悬浮球尺寸设置失败（忽略）');
      }

      // ---- 4) 点击回调（由 FloatBall 页通过 AppStorage 触发）----
      AppStorage.setOrCreate<() => void>('carhiFloatToggle', onToggle);

      this.showing = true;
      hilog.info(DOMAIN, TAG, '★ 悬浮球已显示');
      return { ok: true, message: '' };
    } catch (e) {
      const err = e as BusinessError;
      // 常见错误码：
      //   201       权限被拒（FLOAT_VIEW 未授予 / 普通应用不可用）
      //   801       设备/能力不支持
      //   1300002   窗口状态异常
      const msg: string =
        err.code === 201 ? '悬浮窗权限被拒（普通应用可能无法使用 FLOAT_VIEW）'
          : (err.code === 801 ? '本设备不支持全局悬浮窗'
            : `创建悬浮窗失败 code=${err.code} ${err.message}`);
      hilog.error(DOMAIN, TAG, `★ 悬浮球创建失败：${msg}`);
      this.win = null;
      this.showing = false;
      return { ok: false, message: msg };
    }
  }

  /** 隐藏并销毁悬浮球 */
  async hide(): Promise<void> {
    if (this.win === null) {
      return;
    }
    try {
      await this.win.destroyWindow();
      hilog.info(DOMAIN, TAG, '悬浮球已销毁');
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, `销毁悬浮球失败 code=${err.code}`);
    }
    this.win = null;
    this.showing = false;
  }
}
