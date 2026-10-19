/**
 * 高德导航数据探针（Car Kit 路线已判死并移除）
 *
 * ## 历史背景（2026-10-16 更新）
 *
 * 本文件原本还承担**华为 Car Kit 导航信息服务**的可行性探针
 * （`@kit.CarKit` → `navigationInfoMgr` / `smartMobilityCommon`）。
 * 该路线已于 2026-10-16 **判死并整体移除**，三条依据互相印证：
 *
 *   1. **SDK 层**：`NavigationController` 只有 4 个方法 ——
 *      `updateNavigationStatus` / `updateNavigationMetadata` /
 *      `registerSystemNavigationListener` / `unregisterSystemNavigationListener`，
 *      **2 写 + 2 注册、零读取**，不存在任何 `getNavigationInfo`；
 *      `getNavigationController()` 名字带 get，但取的是**控制器实例**、不是导航数据。
 *   2. **真机实测**：release 包下控制器可获取、监听注册成功，25 秒零回调；
 *      `smartMobilityCommon` 的两个 get 只返回「连接状态 + 虚拟屏归属」
 *      （`DEVICE_TYPE` / `DISPLAY_ID` / `IS_PHONE_DESKTOP`），**不是导航数据**。
 *   3. **官方客服定案**：接口一共只有 4 个方法；`onQueryNavigationInfo` 是
 *      "**系统查询、应用应答**"的被动模式，不是应用侧主动拉取接口。
 *      根因是**应用沙箱** —— 第三方应用读不到其他应用的运行时数据，
 *      "读高德 App 正在导航的数据"在系统层面即被封死。
 *
 * ⇒ 结论：**想拿导航数据，只能在 CarHi 内自己发起导航**（本文件走的高德 SDK 路线）。
 *   相关配置已同步移除：权限 `ACCESS_SERVICE_NAVIGATION_INFO` /
 *   `ACCESS_CAR_DISTRIBUTED_ENGINE`、skills `action.navigation.infoservice`、
 *   metadata `carHopCapability`。
 *
 * ## 本文件现在做什么
 *
 * 走**高德导航 SDK**（`@amap/amap_lbs_navi`）在 CarHi 内**自己发起导航**，
 * 把 `onNaviInfoUpdate` 的数据搬给渲染器。这条路绕开沙箱 ——
 * 数据是本应用自己算出来的，不涉及读别人的运行时数据。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { AmapNaviBridge } from './AmapNaviBridge';

/** 高德 Key（申请时绑定的 appId = com.carhi.carlifephone_BFi95B6...） */
const AMAP_KEY: string = '8a6e96523bbd36ddaa2774c3c6be4a49';

const DOMAIN: number = 0x0001;
const TAG: string = 'CarHiNavi';

/**
 * 高德导航数据探针。
 *
 * ★ 刻意设计成**幂等、可重复调用**：设置页按钮点一次跑一次。
 */
export class NaviInfoProbe {
  /** ★ 高德数据桥（单例，探针与正式逻辑共用） */
  private static bridge: AmapNaviBridge | null = null;
  /** onNaviInfoUpdate 收到的次数（验证数据是否真的在流） */
  private static naviInfoCount: number = 0;
  /** 最近一条真实导航数据摘要 */
  private static lastNaviInfo: string = '';

  /**
   * ★ 端到端验证：初始化高德 → 算路 → 模拟导航 → 观察 onNaviInfoUpdate。
   *
   * 这是验证「数据→渲染→推车机」链路的**最快手段**：
   * 模拟导航不需要真开车，SDK 按虚拟速度走完全程，`onNaviInfoUpdate`
   * 会持续吐出真实导航数据。
   *
   * @param endLat 终点纬度；不传则用默认测试点（天安门）
   * @param endLng 终点经度
   * @param emulator true = 模拟导航（推荐，验证数据通路用）
   *
   * ★ 起点为什么要显式给：本机实测「起点传 null（用当前位置）」算路返回
   *   `errorInfo=3`（起点类错误码）—— 桌面上没有真实 GPS 起点。
   *   显式给一对坐标（如 北京西站→天安门）才能算出路。
   */
  static async runNaviTest(endLat: number, endLng: number, emulator: boolean): Promise<string> {
    hilog.info(DOMAIN, TAG, `=== 高德端到端测试：终点(${endLat},${endLng}) 模拟=${emulator} ===`);

    // 1) 初始化
    const ctx: Context = getContext().getApplicationContext() as Context;
    if (NaviInfoProbe.bridge === null) {
      NaviInfoProbe.bridge = new AmapNaviBridge();
    }
    if (!NaviInfoProbe.bridge.ready) {
      const ok: boolean = NaviInfoProbe.bridge.init(ctx, AMAP_KEY);
      if (!ok) {
        return '✗ 高德初始化失败（看日志 CarHiAmap）';
      }
    }
    const bridge = NaviInfoProbe.bridge;

    // ★ 挂数据观察者：统计 onNaviInfoUpdate 频率 + 留最近一条摘要
    bridge.onUpdate = (snap): void => {
      NaviInfoProbe.naviInfoCount++;
      NaviInfoProbe.lastNaviInfo =
        `路=${snap.road} 距下口=${snap.segRemainDis}m 转=${snap.iconType}`
        + ` 红灯=${snap.remainLightCount}个 车速=${snap.speedKmh}`;
      // 每 10 条记一次日志（高频回调，全记会刷屏）
      if (NaviInfoProbe.naviInfoCount % 10 === 1) {
        hilog.info(DOMAIN, TAG, `[数据#${NaviInfoProbe.naviInfoCount}] ${NaviInfoProbe.lastNaviInfo}`);
      }
    };

    // 2) 算路（★ 起点显式给 —— 北京西站；终点天安门。不依赖 GPS）
    const routeOk: boolean = bridge.startDriveNavi(endLat, endLng, 39.894911, 116.322220);
    if (!routeOk) {
      return '✗ 算路调用失败';
    }

    // 3) 等算路结果，再起导航（算路是异步回调，实测约 10s 才回来）
    return new Promise<string>((resolve) => {
      setTimeout(() => {
        const naviOk: boolean = bridge.startNavi(emulator);
        if (!naviOk) {
          resolve('✗ 算路已发起但 startNavi 失败（算路可能还没回来）');
          return;
        }
        // 4) 再等几秒，看有没有数据进来
        setTimeout(() => {
          resolve(`算路✓ startNavi✓ | onNaviInfoUpdate ×${NaviInfoProbe.naviInfoCount}\n`
            + `最近数据：${NaviInfoProbe.lastNaviInfo || '(还没数据)'}`);
        }, 8000);
      }, 14000);
    });
  }

  /**
   * ★ 确保数据桥已创建并初始化（幂等，2026-10-18 方式2 接线）。
   *
   * 旧入口只有 runNaviTest 会建桥 —— 正式功能（方式2 自绘导航卡）需要
   * 不跑测试也能拿到就绪的桥。重复调用安全，已就绪直接返回 true。
   */
  static ensureInited(): boolean {
    if (NaviInfoProbe.bridge === null) {
      NaviInfoProbe.bridge = new AmapNaviBridge();
    }
    if (NaviInfoProbe.bridge.ready) {
      return true;
    }
    const ctx: Context = getContext().getApplicationContext() as Context;
    return NaviInfoProbe.bridge.init(ctx, AMAP_KEY);
  }

  /** 高德地图 / 导航共用已配置的应用 Key，不在页面层重复存放。 */
  static apiKey(): string {
    return AMAP_KEY;
  }

  /** ★ 取数据桥实例（供页面读取快照 / 挂观察者） */
  static bridgeInstance(): AmapNaviBridge | null {
    return NaviInfoProbe.bridge;
  }

  /** 高德数据接入情况（给设置页显示） */
  static amapStats(): string {
    return `onNaviInfoUpdate ×${NaviInfoProbe.naviInfoCount}\n`
      + `最近：${NaviInfoProbe.lastNaviInfo || '(无)'}`;
  }
}
