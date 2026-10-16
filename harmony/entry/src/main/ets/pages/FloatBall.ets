/**
 * 悬浮球 UI —— 常驻屏幕的圆形按钮，点一下开/关投屏。
 *
 * ## 为什么单独一个页面
 *
 * 悬浮窗（`TYPE_FLOAT`）需要自己的窗口内容。它**不注册在 `main_pages.json`**
 * （那是主窗口的路由表），而是由 `FloatBall.show()` 通过
 * `window.loadContent('pages/FloatBall')` 直接加载，所以**必须存在这个文件**
 * 但不进主路由。
 *
 * ## 交互
 * - 单击 → 切换投屏开关（回调存在 `AppStorage['carhiFloatToggle']`）
 * - 拖动 → 移动悬浮球位置（**待实现**，需要配合窗口 moveWindowTo）
 *
 * ## 视觉
 * 深色半透明圆 + 状态色：
 * - 灰色 = 未投屏
 * - 绿色 = 投屏中
 */

@Component
export struct FloatBallPage {
  @StorageLink('carhiFloatOn') floatOn: boolean = false;

  build() {
    Stack() {
      // 圆形按钮
      Column() {
        // 用简单图形表示"投屏"：一个方框 + 一条推送箭头
        Text(this.floatOn ? '■' : '▶')
          .fontSize(34)
          .fontColor('#FFFFFF')
      }
      .width(88)
      .height(88)
      .borderRadius(44)
      .backgroundColor(this.floatOn ? '#238636EE' : '#30363DEE')
      .border({ width: 2, color: this.floatOn ? '#3FB950' : '#484F58' })
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        // 取回调并执行（回调由 FloatBall.show 注入，指向 Index 的投屏开关）
        const cb = AppStorage.get<() => void>('carhiFloatToggle');
        if (cb !== undefined) {
          cb();
        }
      })
    }
    .width(100)
    .height(100)
  }
}

/**
 * 悬浮窗入口。
 *
 * ⚠ 悬浮窗的 root 组件名必须能被子窗口加载 —— 这里用 `@Entry` 之外的方式不行，
 *   所以需要一个最小的 `@Entry` 包装（悬浮窗 loadContent 走的是页面路由机制）。
 */
@Entry
@Component
struct FloatBallEntrance {
  build() {
    Stack() {
      FloatBallPage()
    }
    .width(100)
    .height(100)
  }
}
