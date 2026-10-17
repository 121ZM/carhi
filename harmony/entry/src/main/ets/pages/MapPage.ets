/**
 * 真地图页（MapPage）—— 手机端**直嵌高德 `MapViewComponent`**
 *
 * ## 这条路要解决什么
 *
 * 车机上现在的"地图"是 `cpp/hmi_renderer.cpp::DrawMap()` 画的**示意图**
 * （网格 + 写死折线），没有任何路网/瓦片数据。
 *
 * 已核实结论（不再推翻）：
 *   - 高德 SDK 的护城河在**渲染侧**（夜景/导航态/红绿灯倒计时/路口放大图），
 *     这些**进不了** native `OH_Drawing` 自绘。
 *   - `AMapNavi` 的结构化数据（路名/转向/剩余里程/红绿灯数量）已经拿到了
 *     （见 `core/AmapNaviBridge.ets`），但那是"数据"不是"地图"。
 *   - ⇒ **唯一能拿到真地图的路**：手机端直嵌 `MapViewComponent`，
 *     再靠 `OH_AVScreenCapture` 全屏采集推给车机。
 *
 * ## 已知约束（不要试图绕）
 *
 * `OH_CAPTURE_SPECIFIED_WINDOW` 需要 `missionIDs`，而整个 ArkTS API 面
 * 搜 `missionId` 零命中 —— 第三方应用拿不到自己的 missionID，
 * 所以"只采自己窗口"走不通。⇒ **必须接受「车机画面 = 手机整屏」**：
 * 手机得亮屏、常驻显示本页。
 *
 * ## 本页职责边界
 *
 * 只负责**把真地图画在手机屏幕上**（含 Marker/Polyline 覆盖物）。
 * 采集/编码/推流是既有链路（`ScreenCaptureSource` → 编码器 → 车机）的事。
 *
 * ## 接入方式
 *
 * 普通 `@Component` 页面，由 `Index.ets` 条件挂载；车机投屏由用户显式点击触发，
 * 复用现有 `ScreenCaptureSource` 全屏采集链路。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import ArrayList from '@ohos.util.ArrayList';
import {
  AMap,
  BitmapDescriptorFactory,
  CameraUpdateFactory,
  LatLng,
  MapsInitializer,
  MapView,
  MapViewComponent,
  MapViewCreateCallback,
  MapViewManager,
  MarkerOptions,
  PolylineOptions,
  UiSettings
} from '@amap/amap_lbs_map3d';
import { AMapPrivacyShowStatus, AMapPrivacyInfoStatus, AMapPrivacyAgreeStatus }
  from '@amap/amap_lbs_common';
import { NaviInfoProbe } from '../core/NaviInfoProbe';

/** hilog domain（固定 0x0001） */
const DOMAIN: number = 0x0001;
/** hilog tag（固定 CarHi，按它过滤日志） */
const TAG: string = 'CarHi';

/** 首帧相机中心：上海市中心（人民广场），GCJ-02 */
const CENTER_LAT: number = 31.2304;
const CENTER_LNG: number = 121.4737;
/** 首帧缩放级别（3-20） */
const CENTER_ZOOM: number = 15;

/**
 * 模拟导航路线（人民广场 → 外滩）。
 * 写死坐标即可 —— 本页目标是"证明真地图能显示"，不是真算路。
 */
const ROUTE: number[][] = [
  [31.2304, 121.4737],
  [31.2330, 121.4780],
  [31.2360, 121.4830],
  [31.2397, 121.4900]
];

/**
 * 真地图页。
 *
 * ★ ArkTS 已知坑（本项目既有）：
 *   普通字段不驱动 UI 刷新，**需要刷新的必须镜像成 `@State`**。
 *   所以 `mapReady` / `errText` / `carLat` / `carLng` / `trafficOn` 全是 `@State`。
 */
@Component
export struct MapPage {
  /** 退出回调（宿主决定何时移除本页） */
  onExit: () => void = () => {};
  /** 当前是否正在把手机整屏投到车机 */
  @Prop castActive: boolean = false;
  /** 用户显式开启或停止车机投屏 */
  onToggleCast: () => void = () => {};

  /** AMap 实例（拿到后才能加覆盖物 / 控相机） */
  private aMap: AMap | null = null;
  /** MapView 实例（用于生命周期 onCreate / onDestroy） */
  private mapView: MapView | null = null;
  /** 创建回调句柄（保存下来以便反注册，避免重复注册） */
  private createCb: MapViewCreateCallback | null = null;

  /** 地图是否就绪（★ @State 镜像） */
  @State private mapReady: boolean = false;
  /** 错误文案（★ @State 镜像；非空即显示错误页） */
  @State private errText: string = '';
  /** 车标纬度（模拟车位置，★ @State 镜像） */
  @State private carLat: number = CENTER_LAT;
  /** 车标经度（★ @State 镜像） */
  @State private carLng: number = CENTER_LNG;
  /** 交通路况图层开关（★ @State 镜像） */
  @State private trafficOn: boolean = true;

  aboutToAppear(): void {
    this.initMap();
  }

  aboutToDisappear(): void {
    // 反注册回调，避免宿主反复挂载时重复注册
    if (this.createCb !== null) {
      try {
        MapViewManager.getInstance().unregisterMapViewCreatedCallback(this.createCb);
      } catch (e) {
        // 忽略
      }
      this.createCb = null;
    }
    // 销毁地图（释放引擎资源）
    if (this.mapView !== null) {
      try {
        this.mapView.onDestroy();
      } catch (e) {
        // 忽略
      }
      this.mapView = null;
    }
    this.aMap = null;
  }

  /**
   * 初始化地图。
   *
   * ★ 顺序铁律：
   *   隐私合规 → setApiKey → 注册创建回调 →（MapViewComponent 创建）
   *   → mapView.onCreate() → mapView.getMapAsync(AMap)。
   *
   * 来源：`MapsInitializer.d.ets:437/444`（隐私）、`:180`（setApiKey）、
   *       `MapViewManager.d.ets:33`（注册）、`MapView.d.ets:24/28`（onCreate/getMapAsync）。
   */
  private initMap(): void {
    try {
      const ctx: Context = getContext().getApplicationContext() as Context;

      // 1) 隐私合规 —— 必须在 MapViewManager 实例化之前调用
      MapsInitializer.updatePrivacyShow(AMapPrivacyShowStatus.DidShow,
        AMapPrivacyInfoStatus.DidContain, ctx);
      MapsInitializer.updatePrivacyAgree(AMapPrivacyAgreeStatus.DidAgree, ctx);

      // 2) 设置 Key（必须在创建地图之前）
      MapsInitializer.setApiKey(NaviInfoProbe.apiKey());

      // 3) 冷启动首帧相机（可选：避免首帧白屏/飞到默认位置）
      MapsInitializer.setInitCamera(CENTER_LAT, CENTER_LNG, CENTER_ZOOM);

      // 4) 注册「地图创建完成」回调 —— MapViewComponent 构建后触发
      this.createCb = (mapview?: MapView, mapViewName?: string): void => {
        if (mapview === undefined || mapview === null) {
          return;
        }
        this.mapView = mapview;
        hilog.info(DOMAIN, TAG, `MapPage: MapView 已创建 name=${mapViewName ?? ''}`);
        mapview.onCreate();
        mapview.getMapAsync((map: AMap) => {
          this.aMap = map;
          this.onMapReady(map);
        });
      };
      MapViewManager.getInstance().registerMapViewCreatedCallback(this.createCb);

      hilog.info(DOMAIN, TAG, 'MapPage 初始化完成：隐私合规 + Key + 创建回调已就绪');
    } catch (e) {
      const err = e as BusinessError;
      this.errText = `地图初始化失败 code=${err.code} msg=${err.message}`;
      hilog.error(DOMAIN, TAG, this.errText);
    }
  }

  /**
   * 拿到 AMap 后的配置：路况 + 相机 + 覆盖物（Marker / Polyline）。
   *
   * 方法名来源（`AMap.d.ets`）：
   *   `setTrafficEnabled` :559、`moveCamera` :94、`addPolyline` :160、
   *   `addMarker` :232、`getUiSettings` :626。
   */
  private onMapReady(map: AMap): void {
    try {
      // 交通路况图层
      map.setTrafficEnabled(this.trafficOn);

      // 相机：定位到上海市中心
      map.moveCamera(CameraUpdateFactory.newLatLngZoom(
        new LatLng(this.carLat, this.carLng), CENTER_ZOOM));

      // 保留缩放按钮 + 指南针（`UiSettings.d.ets:28/35`）
      const ui: UiSettings | undefined = map.getUiSettings();
      if (ui !== undefined && ui !== null) {
        ui.setZoomControlsEnabled(true);
        ui.setCompassEnabled(true);
      }

      // ★ 覆盖物 1：导航路线（Polyline）
      const line = new PolylineOptions();
      const pts = new ArrayList<LatLng>();
      for (let i = 0; i < ROUTE.length; i++) {
        pts.add(new LatLng(ROUTE[i][0], ROUTE[i][1]));
      }
      line.addAll(pts);
      line.setWidth(18);
      line.setColor(0xFF2F81F7);   // 32 位 ARGB
      map.addPolyline(line);

      // ★ 覆盖物 2：车位置 Marker
      const car = new MarkerOptions();
      car.setPosition(new LatLng(this.carLat, this.carLng));
      car.setTitle('车位置');
      car.setSnippet('模拟车位置');
      car.setIcon(BitmapDescriptorFactory.defaultMarker());
      map.addMarker(car);

      // ★ 覆盖物 3：终点 Marker
      const dest = new MarkerOptions();
      dest.setPosition(new LatLng(ROUTE[ROUTE.length - 1][0], ROUTE[ROUTE.length - 1][1]));
      dest.setTitle('终点');
      dest.setSnippet('外滩');
      map.addMarker(dest);

      this.mapReady = true;
      hilog.info(DOMAIN, TAG, '★ MapPage 地图就绪：路况已开，已加 Marker×2 + Polyline×1');
    } catch (e) {
      const err = e as BusinessError;
      this.errText = `地图配置失败 code=${err.code} msg=${err.message}`;
      hilog.error(DOMAIN, TAG, this.errText);
    }
  }

  build() {
    Stack() {
      // 底层：真地图（高德引擎渲染）
      if (this.errText.length === 0) {
        MapViewComponent()
          .width('100%')
          .height('100%')
      }

      // 顶层：操作栏。投屏明确由用户点击触发，系统另会显示屏幕采集授权弹窗。
      Row({ space: 10 }) {
        Button('返回设置')
          .fontSize(12)
          .onClick(() => this.onExit())
        Text(this.mapReady ? '高德真地图 · 演示路线' : '高德真地图')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .layoutWeight(1)
        Button(this.castActive ? '停止投屏' : '投屏到车机')
          .fontSize(12)
          .onClick(() => this.onToggleCast())
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 8, bottom: 8 })
      .backgroundColor('#CC0D1117')
      .alignItems(VerticalAlign.Center)
      .align(Alignment.Top)

      // 顶层：加载提示（居中，避开状态栏/导航栏区域）
      if (!this.mapReady && this.errText.length === 0) {
        Column() {
          LoadingProgress().width(48).height(48)
          Text('正在加载高德地图…').fontSize(14).fontColor('#C9D1D9').margin({ top: 12 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }

      // 顶层：错误提示（居中）
      if (this.errText.length > 0) {
        Column() {
          Text('高德地图启动失败').fontSize(18).fontColor('#FF7B72')
          Text(this.errText).fontSize(12).fontColor('#C9D1D9').margin({ top: 8 })
          Button('返回').onClick(() => this.onExit()).margin({ top: 16 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#0D1117')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0D1117')
  }
}
