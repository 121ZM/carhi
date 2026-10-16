/**
 * 高德导航页（A3′ 方案）—— **用高德原生组件渲染导航画面**
 *
 * ## 这条路要解决什么
 *
 * 大哥的核心诉求：**画面要像 CarWith 那样，是高德渲染的**（有地图、路线、
 * 红绿灯、路口放大图），而不是我们手画的"文字卡片"。
 *
 * 之前 `AmapNaviBridge` 只接了**数据**（路名/距离/转向），画面仍是我们
 * `HmiRenderer` 用 `OH_Drawing` 手画的 —— 所以车机上只看到文字描述。
 *
 * 本页解决画面问题：把高德的 `AMapNaviComponent`（`@Component struct`，
 * 官方注释明确「添加此组件到页面中，并且占满整个屏幕」）嵌进来，
 * 让**高德自己渲染完整导航界面**。
 *
 * ## 组件结构（照官方文档 guide/navi-component/basic-functions）
 *
 * ```
 * AMapNaviView（视图实例：配置项，如 setViewOptions）
 *       ↓ naviView 属性传入
 * AMapNaviComponent({ appCustomerConfig, naviView })   ← 放进 build()
 * ```
 *
 * ★ 注意 `AMapNaviView` **不是** `@Component`，只是视图实例；
 *   真正能进 `build()` 的是 `AMapNaviComponent`。
 *
 * ## 与推流的关系（★ 这是本方案的关键约束）
 *
 * 高德组件画在**手机屏幕上**（ArkUI 渲染）。
 * 要推给车机，需要把画面像素导出 —— 走项目已有的
 * `getComponentSnapshot()` 截图通路（`startFallbackPush` 在用同一个 API），
 * **不碰 `OH_AVScreenCapture` 录屏**（那条路切后台会停摆，已废弃）。
 *
 * 详见后续 `AmapCastBridge`（截图导出 → 编码器）。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import {
  AMapNaviComponent,
  AMapNaviView,
  AMapNaviViewOptions,
  AMapNaviFactory,
  AMap,
  AmapNaviType,
  AMapPageType,
  INaviInfoCallback,
  IAMapNavi,
  INaviInfo,
  NaviType,
  NaviLatLng,
  NaviPoi,
  NaviSetting,
  PathPlanningStrategy
} from '@amap/amap_lbs_navi';
import { AMapPrivacyShowStatus, AMapPrivacyInfoStatus, AMapPrivacyAgreeStatus }
  from '@amap/amap_lbs_common';

const DOMAIN: number = 0x0001;
const TAG: string = 'CarHiNaviView';

/** 高德 Key（与 NaviInfoProbe.ets 里同一个） */
const AMAP_KEY: string = '8a6e96523bbd36ddaa2774c3c6be4a49';

/**
 * 导航页 —— 全屏高德原生导航组件。
 *
 * 用法：由 `Index.ets` 在需要时切到本页（`page === 2` 之类），
 * 传入起终点即开始导航。
 */
@Component
export struct AmapNaviPage {
  /** 起点（不传则用「我的位置」） */
  startLat: number = 0;
  startLng: number = 0;
  startName: string = '';
  /** 终点（必填） */
  endLat: number = 39.908722;
  endLng: number = 116.397499;
  endName: string = '终点';
  /** true = 模拟导航（验证用，不用真开车） */
  emulator: boolean = true;
  /** 退出回调（回到设置页） */
  onExit: () => void = () => {};

  /**
   * ★ 画面帧回调：把高德**引擎截图**交出去（由 Index 转成 RGBA 喂编码器）。
   *
   * 为什么不在这里直接推：本页只管渲染与取图，推流链路的持有者（编码器、
   * `NativeHmiSource`）在 Index 侧；分层清楚，也便于页面销毁时解绑。
   *
   * @param bmp  高德引擎截出的地图画面（PixelMap）
   * @param w    宽
   * @param h    高
   */
  onFrame: (bmp: image.PixelMap, w: number, h: number) => void = () => {};

  /** 导航视图实例（必须先建，再传给组件） */
  private naviView: AMapNaviView = new AMapNaviView();
  /** 高德导航单例（引擎） */
  private navi: IAMapNavi | null = null;
  /** ★ 地图对象（引擎截图的入口） */
  private map: AMap | null = null;
  /** 引擎截图定时器 */
  private shotTimer: number = -1;
  /** 同一时刻只允许一个截图在飞（引擎截图是异步回调） */
  private shotBusy: boolean = false;
  /** 截图计数（诊断） */
  private shotCount: number = 0;
  /** 是否已初始化 */
  @State private ready: boolean = false;
  @State private errText: string = '';

  /** 引擎截图频率（ms）。导航画面变化不快，8fps 足够，且省 CPU。 */
  private static readonly SHOT_INTERVAL_MS: number = 120;

  aboutToAppear(): void {
    this.initAmap();
  }

  aboutToDisappear(): void {
    this.stopEngineShot();
    // 离开页面时释放（下次进来重建，避免单例状态残留）
    try {
      if (this.navi !== null) {
        this.navi.stopNavi();
      }
    } catch (e) {
      // 忽略
    }
  }

  /**
   * ★ 启动「引擎级截图」循环 —— 本方案的画面来源。
   *
   * 与「截 ArkUI 组件」（`getComponentSnapshot`）的区别：
   *   - 组件截图：截整屏 1272×2860 再压到 1280×720，**90% 像素白采**，
   *     且高频调用不稳（实测 3 帧就停）。
   *   - **引擎截图**：`map.getMapScreenShot()` 从**地图引擎内部**直接出图，
   *     拿到的是纯导航画面，开销小、官方支持（为 HUD/车机场景设计）。
   */
  private startEngineShot(): void {
    if (this.shotTimer !== -1) {
      return;
    }
    this.shotTimer = setInterval(() => {
      if (this.shotBusy || this.map === null) {
        return;
      }
      this.shotBusy = true;
      try {
        // 发起引擎截图（异步回调）
        this.map.getMapScreenShot({
          onMapScreenShot: (bmp: image.PixelMap | undefined, status: number): void => {
            this.shotBusy = false;
            if (bmp === undefined) {
              return;
            }
            // ★ status 的含义：截图那一瞬间地图**是否正在发生变化**
            //   （1 = 有变化/渲染中，0 = 画面静止）。
            //   ⚠️ 早期版本把 status!==1 当"无效帧"丢弃 → 地图静止时永远丢帧，
            //      表现为"只推了开头两帧就不动了"（2026-10-15 真机踩到）。
            //   正确做法：**只要拿到位图就用**，status 仅作诊断。
            try {
              const info = bmp.getImageInfoSync();
              const w: number = info.size.width;
              const h: number = info.size.height;
              this.shotCount++;
              // 前 5 帧逐帧打，之后每 50 帧打一次（诊断持续性）
              if (this.shotCount <= 5 || this.shotCount % 50 === 0) {
                hilog.info(DOMAIN, TAG, `★ 引擎截图 #${this.shotCount}：${w}x${h}（status=${status}）`);
              }
              this.onFrame(bmp, w, h);
            } catch (e) {
              const err = e as Error;
              hilog.error(DOMAIN, TAG, `引擎截图处理失败: ${err.message}`);
            } finally {
              bmp.release();
            }
          }
        });
      } catch (e) {
        this.shotBusy = false;
        const err = e as BusinessError;
        hilog.error(DOMAIN, TAG, `getMapScreenShot 异常 code=${err.code} msg=${err.message}`);
      }
    }, AmapNaviPage.SHOT_INTERVAL_MS);
    hilog.info(DOMAIN, TAG, `★ 引擎截图循环已启动（${1000 / AmapNaviPage.SHOT_INTERVAL_MS} fps）`);
  }

  /** 停止引擎截图 */
  private stopEngineShot(): void {
    if (this.shotTimer !== -1) {
      clearInterval(this.shotTimer);
      this.shotTimer = -1;
    }
    this.shotBusy = false;
  }

  /**
   * 初始化高德引擎 + 配置视图。
   *
   * ★ 顺序铁律：隐私合规 → getAMapNaviInstance → 配置 View。
   */
  private initAmap(): void {
    try {
      const ctx: Context = getContext().getApplicationContext() as Context;

      // 1) 隐私合规（必须最先）
      NaviSetting.updatePrivacyShow(AMapPrivacyShowStatus.DidShow,
        AMapPrivacyInfoStatus.DidContain, ctx);
      NaviSetting.updatePrivacyAgree(AMapPrivacyAgreeStatus.DidAgree, ctx);

      // 2) 导航单例
      this.navi = AMapNaviFactory.getAMapNaviInstance(ctx, AMAP_KEY);
      if (this.navi === null) {
        this.errText = '高德导航单例创建失败';
        return;
      }

      // 3) 视图配置：用默认配置即可（高德的默认样式就是它 App 里那套）
      const opts = new AMapNaviViewOptions();
      // 保持默认的「显示红绿灯」（官方默认 true，这里显式写出表明意图）
      opts.setTrafficLightsVisible(true);
      this.naviView.setViewOptions(opts);

      this.ready = true;
      hilog.info(DOMAIN, TAG, '★ 导航页就绪：高德引擎 + 视图已配置');

      // ★ 等地图初始化完成后拿到 AMap 对象（引擎截图的入口），再启动截图循环
      this.naviView.getMapAsync((map: AMap) => {
        this.map = map;
        hilog.info(DOMAIN, TAG, '★ 地图对象已就绪，启动引擎截图');
        this.startEngineShot();
      });
    } catch (e) {
      const err = e as BusinessError;
      this.errText = `初始化失败 code=${err.code} msg=${err.message}`;
      hilog.error(DOMAIN, TAG, this.errText);
    }
  }

  /** 构造组件参数（起终点） */
  private buildParams(): IAmapNaviParamsLike {
    const end: NaviPoi = new NaviPoi(this.endName, new NaviLatLng(this.endLat, this.endLng), null);
    let start: NaviPoi | null = null;
    if (this.startLat !== 0 && this.startLng !== 0) {
      start = new NaviPoi(this.startName.length > 0 ? this.startName : '起点',
        new NaviLatLng(this.startLat, this.startLng), null);
    }
    return {
      mType: AmapNaviType.Driver,
      mNaviType: this.emulator ? NaviType.EMULATOR : NaviType.GPS,
      start: start ?? undefined,
      end: end,
      mRouteStrategy: PathPlanningStrategy.DRIVING_MULTIPLE_ROUTES_DEFAULT,
      serviceAreaDetailsEnable: true,
      isNeedCalculateRouteWhenPresent: true,
      goBack: () => {
        hilog.info(DOMAIN, TAG, '高德组件请求返回');
        this.onExit();
      }
    };
  }

  build() {
    Stack() {
      if (this.errText.length > 0) {
        // 初始化失败：显示原因，便于排查
        Column() {
          Text('高德导航组件启动失败').fontSize(18).fontColor('#FF7B72')
          Text(this.errText).fontSize(12).fontColor('#C9D1D9').margin({ top: 8 })
          Button('返回').onClick(() => this.onExit()).margin({ top: 16 })
        }
        .width('100%').height('100%').justifyContent(FlexAlign.Center)
        .backgroundColor('#0D1117')
      } else if (this.ready) {
        // ★ 高德原生导航组件：占满全屏（官方要求）
        AMapNaviComponent({
          appCustomerConfig: this.buildParams(),
          naviView: this.naviView
        })
          .width('100%')
          .height('100%')
      } else {
        Column() {
          LoadingProgress().width(48).height(48)
          Text('正在初始化高德导航…').fontSize(14).fontColor('#C9D1D9').margin({ top: 12 })
        }
        .width('100%').height('100%').justifyContent(FlexAlign.Center)
        .backgroundColor('#0D1117')
      }
    }
    .width('100%')
    .height('100%')
  }
}

/**
 * `appCustomerConfig` 的结构化类型别名。
 *
 * 直接用 `IAmapNaviParams` 接口会因 ArkTS 的「无类型对象字面量」限制报错
 * （`arkts-no-untyped-obj-literals`），所以这里给字面量一个具名类型。
 */
interface IAmapNaviParamsLike {
  mType: AmapNaviType;
  mNaviType: NaviType;
  start?: NaviPoi;
  end: NaviPoi;
  mRouteStrategy: number;
  serviceAreaDetailsEnable: boolean;
  isNeedCalculateRouteWhenPresent: boolean;
  goBack: () => void;
}
