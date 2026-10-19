/**
 * 高德导航数据桥 —— 把 AMapNavi 的实时导航数据「搬运」给 CarHi 渲染器
 *
 * ## 这条路要解决什么
 *
 * 大哥定的目标：**复用高德的导航能力（含红绿灯、路口图），画面推到车机**。
 *
 * 前面已经查证过三条路，结论如下（都有实测/源码证据，别重复走）：
 *   - ❌ Car Kit `navigationInfoMgr`：**结构上没有「读取」入口**（只有上报/应答），
 *        高德、花瓣导航中实测**零回调**。判死。
 *   - ❌ 系统级屏幕镜像（CarWith/CarLife 手机端那套）：需要 `CAPTURE_VIDEO_OUTPUT`
 *        等 **system|privileged 权限**，普通应用拿不到。判死。
 *   - ✅ **高德导航 SDK（本文件）**：官方提供、`normal` 权限即可用、数据结构完整。
 *
 * ## 数据能力（已从 SDK 的 `INaviInfo.d.ets` 核实）
 *
 * 能拿到**结构化数据**的：
 *   `mCurRoadName` 当前路名 / `mNextRoadName` 下条路名 / `mIcon` 转向类型 /
 *   `mSegRemainDis` 距下个路口距离 / `mRouteRemainDis` 总剩余距离 /
 *   `mRouteRemainTime` 剩余时间 / `currentSpeed` 当前车速 /
 *   **`routeRemainLightCount` 前方红绿灯数量** /
 *   `iconBitmap` **转向图标位图** / `crossIconBitmap` **路口放大图位图**
 *
 * ⚠️ 拿不到**结构化数据**的（只有画面）：
 *   红绿灯**倒计时/灯色** —— SDK 里 `setTrafficLightsVisible()` 只有显隐开关，
 *   `onShowTrafficLight()` 是**无参**事件。要看倒计时必须嵌 `AMapNaviView` 渲染。
 *   → 本实现先做「自绘 + 红绿灯数量」，画面风格可控且能复用我们的 CarWith 版式。
 *
 * ## 与渲染器的对接
 *
 * 本类只负责「取数据 → 填 HmiState 字段」，**不画面**。
 * 渲染由既有的 `HmiRenderer`（native 自绘）负责，推流由既有链路负责。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import ArrayList from '@ohos.util.ArrayList';
import {
  AMapNaviFactory,
  AMapNavi,
  IAMapNavi,
  IAMapNaviListener,
  INaviInfo,
  INaviLatLng,
  NaviLatLng,
  NaviSetting,
  NaviType,
  PathPlanningStrategy
} from '@amap/amap_lbs_navi';
import { AMapPrivacyShowStatus, AMapPrivacyInfoStatus, AMapPrivacyAgreeStatus }
  from '@amap/amap_lbs_common';

const DOMAIN: number = 0x0001;
const TAG: string = 'CarHiAmap';

/** 高德数据 → CarHi 渲染器字段的映射结果 */
export interface AmapNaviSnapshot {
  /** 是否正在导航 */
  navigating: boolean;
  /** 当前路名 */
  road: string;
  /** 下条路名 */
  nextRoad: string;
  /** 转向类型（原始高德枚举，待映射） */
  iconType: number;
  /** 距下个路口的距离（米） */
  segRemainDis: number;
  /** 总剩余距离（米） */
  routeRemainDis: number;
  /** 总剩余时间（秒） */
  routeRemainTime: number;
  /** 当前车速 km/h */
  speedKmh: number;
  /** ★ 前方剩余红绿灯**数量**（不是倒计时） */
  remainLightCount: number;
  /** 转向图标位图（高德画好的，可能为 null） */
  turnIcon: image.PixelMap | null;
}

/**
 * 导航数据桥。
 *
 * 用法（外层）：
 *   const bridge = new AmapNaviBridge();
 *   bridge.init(context, API_KEY);       // 建单例、挂监听
 *   bridge.startNavi(from, to);          // 发起导航（或在高德 View 里发起）
 *   const snap = bridge.snapshot();      // 每帧读快照 → 填 HmiState
 */
export class AmapNaviBridge {
  private navi: IAMapNavi | null = null;
  private inited: boolean = false;

  /**
   * 数据更新观察者（可选）。
   *
   * 用回调而非让外部轮询，是为了让「数据到了」这件事立即可见 ——
   * 验证阶段靠着它统计 onNaviInfoUpdate 频率，判断数据是否真的在流。
   */
  onUpdate: ((snap: AmapNaviSnapshot) => void) | null = null;

  /**
   * ★ 算路成功回调（2026-10-18 方式2 接线）。
   *
   * 算路是异步的（实测 10s+），旧探针用「固定等 14s 再 startNavi」很脆；
   * 有了这个回调，外部在算路返回的第一时间接 startNavi 即可。
   */
  onRouteReady: (() => void) | null = null;

  /** 最新快照（监听回调里持续更新，渲染线程读） */
  private snap: AmapNaviSnapshot = {
    navigating: false,
    road: '',
    nextRoad: '',
    iconType: 0,
    segRemainDis: 0,
    routeRemainDis: 0,
    routeRemainTime: 0,
    speedKmh: 0,
    remainLightCount: 0,
    turnIcon: null
  };

  /**
   * 初始化高德导航单例。
   *
   * ★ context 必须传 `getContext().getApplicationContext()`
   *   （SDK 文档明确强调，传错会初始化失败）。
   * ★ key 必须在**任何**高德接口调用**之前**设置。
   */
  init(context: Context, key: string): boolean {
    if (this.inited) {
      return true;
    }
    try {
      // ★ 第一步必须是隐私合规 —— 高德从导航 8.1.0 起强制要求，
      //   不调会抛异常甚至崩溃（本机实测过，见 MEMORY §7.5）。
      //   顺序铁律：隐私合规 → getAMapNaviInstance → addAMapNaviListener。
      NaviSetting.updatePrivacyShow(AMapPrivacyShowStatus.DidShow,
        AMapPrivacyInfoStatus.DidContain, context);
      NaviSetting.updatePrivacyAgree(AMapPrivacyAgreeStatus.DidAgree, context);
      hilog.info(DOMAIN, TAG, '高德隐私合规已声明');

      // ★ context 必须是 ApplicationContext（SDK 文档明确强调）
      this.navi = AMapNaviFactory.getAMapNaviInstance(context, key);
      if (this.navi === null) {
        hilog.error(DOMAIN, TAG, 'getAMapNaviInstance 返回 null');
        return false;
      }
      this.navi.addAMapNaviListener(this.buildListener());
      this.inited = true;
      hilog.info(DOMAIN, TAG, '★ 高德导航单例初始化成功，已挂监听');
      return true;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, `高德初始化失败 code=${err.code} msg=${err.message}`);
      return false;
    }
  }

  /**
   * 发起驾车导航。
   *
   * @param endLat 终点纬度（GCJ-02，高德坐标系）
   * @param endLng 终点经度
   * @param fromLat 起点纬度；**传 null 才会用当前位置**
   * @param fromLng 起点经度
   * @returns 算路是否**发起成功**（注意：返回 true 只表示调用被接受，
   *          真正的结果在 `onCalculateRouteSuccess` 回调里）
   *
   * ★ 起点为什么要能显式给：本机实测「起点传 null（=用当前位置）」时算路返回
   *   `errorInfo=3`（`PathPlanningErrCode` 里对应起点类错误）—— 因为模拟导航
   *   场景下没有真实 GPS 起点。**显式给起点是验证阶段的可靠做法**。
   */
  startDriveNavi(endLat: number, endLng: number,
                 fromLat: number | null = null, fromLng: number | null = null): boolean {
    if (this.navi === null) {
      hilog.error(DOMAIN, TAG, 'startDriveNavi 失败：未初始化');
      return false;
    }
    try {
      const to = new ArrayList<INaviLatLng>();
      to.add(new NaviLatLng(endLat, endLng));

      // 起点：显式给就用给的，否则 null（走"当前位置"）
      let from: ArrayList<INaviLatLng> | null = null;
      if (fromLat !== null && fromLng !== null) {
        from = new ArrayList<INaviLatLng>();
        from.add(new NaviLatLng(fromLat, fromLng));
      }

      const ok: boolean = this.navi.calculateDriveRoute(
        from, to, null, PathPlanningStrategy.DRIVING_MULTIPLE_ROUTES_DEFAULT);
      hilog.info(DOMAIN, TAG, `算路已发起 ok=${ok}`
        + ` 起点=${from === null ? '(当前位置)' : `(${fromLat},${fromLng})`}`
        + ` 终点=(${endLat},${endLng})`);
      return ok;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, `算路抛异常 code=${err.code} msg=${err.message}`);
      return false;
    }
  }

  /**
   * 开始导航（把 `calculateDriveRoute` 拿到的路径跑起来）。
   *
   * @param emulator true = **模拟导航**（不用真跑车，SDK 按虚拟速度走完全程，
   *                 是验证数据通路的最佳手段）；false = 真实 GPS 导航
   *
   * ★ 模拟导航对当前阶段价值极高：不用开车就能看到 `onNaviInfoUpdate`
   *   持续吐出真实数据（转向/距离/路名），可以完整验证「数据→渲染→推车机」链路。
   */
  startNavi(emulator: boolean): boolean {
    if (this.navi === null) {
      return false;
    }
    try {
      const t: number = emulator ? NaviType.EMULATOR : NaviType.GPS;
      const ok: boolean = this.navi.startNavi(t);
      hilog.info(DOMAIN, TAG, `startNavi(emulator=${emulator}) ok=${ok}`);
      return ok;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, `startNavi 抛异常 code=${err.code} msg=${err.message}`);
      return false;
    }
  }

  /** 停止导航 */
  stopNavi(): void {
    if (this.navi !== null) {
      try {
        this.navi.stopNavi();
        this.snap.navigating = false;
      } catch (e) {
        // 忽略
      }
    }
  }

  /**
   * 构造监听器。
   *
   * 只挂我们真正需要的回调 —— 挂多了会让 SDK 侧走更多序列化，
   * 而导航中 `onNaviInfoUpdate` 是高频回调，越轻越好。
   */
  private buildListener(): IAMapNaviListener {
    return {
      // ★ 核心：导航信息更新（高频）。转向/距离/路名/图标/红绿灯数都在这。
      onNaviInfoUpdate: (info: INaviInfo): void => {
        this.snap.navigating = true;
        this.snap.road = info.mCurRoadName ?? '';
        this.snap.nextRoad = info.mNextRoadName ?? '';
        this.snap.iconType = info.mIcon;
        this.snap.segRemainDis = info.mSegRemainDis;
        this.snap.routeRemainDis = info.mRouteRemainDis;
        this.snap.routeRemainTime = info.mRouteRemainTime;
        this.snap.speedKmh = info.currentSpeed;
        this.snap.remainLightCount = info.routeRemainLightCount;
        this.snap.turnIcon = info.iconBitmap;
        // 通知观察者（验证阶段用来统计频率 / 显示最近一条）
        if (this.onUpdate !== null) {
          this.onUpdate(this.snap);
        }
      },

      // 导航起止
      onStartNavi: (type: number): void => {
        this.snap.navigating = true;
        hilog.info(DOMAIN, TAG, `高德开始导航 type=${type}`);
      },
      onStopNavi: (): void => {
        this.snap.navigating = false;
        hilog.info(DOMAIN, TAG, '高德停止导航');
      },
      onArriveDestination: (): void => {
        this.snap.navigating = false;
        hilog.info(DOMAIN, TAG, '★ 已到达目的地');
      },

      // 算路
      onCalculateRouteSuccess: (): void => {
        hilog.info(DOMAIN, TAG, '高德算路成功');
        if (this.onRouteReady !== null) {
          this.onRouteReady();
        }
      },
      onCalculateRouteFailure: (errorInfo: number): void => {
        hilog.error(DOMAIN, TAG, `高德算路失败 errorInfo=${errorInfo}`);
      },

      // 偏航重算
      onReCalculateRouteForYaw: (): void => {
        hilog.info(DOMAIN, TAG, '偏航，高德重算路线');
      },

      // GPS 状态
      onGpsSignalWeak: (isWeak: boolean): void => {
        hilog.info(DOMAIN, TAG, `GPS 信号${isWeak ? '弱' : '恢复'}`);
      },

      // 红绿灯「显示」通知（★ 无数据，只说明要画红绿灯了）
      onShowTrafficLight: (): void => {
        hilog.info(DOMAIN, TAG, '前方有红绿灯（SDK 仅通知，倒计时需 View 渲染）');
      },

      // 导航播报文本（可转发给车机做 TTS）
      onGetNavigationTextAndType: (text: string | null, type: number): void => {
        if (text !== null && text.length > 0) {
          hilog.info(DOMAIN, TAG, `播报[${type}]: ${text}`);
        }
      }
    };
  }

  /** 读当前快照（供渲染器每帧取用；无锁 —— 字段是值类型，读到的是一致性可接受的快照） */
  snapshot(): AmapNaviSnapshot {
    return this.snap;
  }

  /** 是否已初始化 */
  get ready(): boolean {
    return this.inited;
  }

  /** 释放导航单例（退出时调） */
  release(): void {
    if (this.navi !== null) {
      try {
        this.navi.stopNavi();
      } catch (e) {
        // 忽略：可能本来就没在导航
      }
    }
    this.inited = false;
    this.navi = null;
  }
}
