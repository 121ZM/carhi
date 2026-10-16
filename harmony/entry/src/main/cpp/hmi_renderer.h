/*
 * CarHi 车机 HMI 渲染器（Native）—— 路线 A1：纯自绘
 *
 * ## 为什么需要它
 *
 * 2026-10-14 实测：前台推流已经能出画面，但走的是
 *   ArkUI 界面 → componentSnapshot.getSync('hmi_root') → PixelMap → 拷进编码器
 * 这条路有两个死结：
 *   1. 截图 ~26ms/帧，且**切后台后系统停渲染** → 后台画面冻结（推流是刚需）。
 *   2. 每帧一次 14MB 的 RGBA 拷贝。
 * 离屏快照（createFromBuilder）实测 345ms/帧（≈2fps），已判死。
 *
 * → 结论：只能像官方 CarLife 一样，**自己渲染**。UI 的绘制权必须在我们手里。
 *
 * ## 为什么不用手写 OpenGL
 *
 * 手写 GL 的最大代价是文字（要自己做字形图集 + 排版）。而 SDK 里有一条现成的路：
 *
 *   OH_Drawing_GpuContextCreate()                       // Skia GPU 上下文
 *   OH_Drawing_SurfaceCreateOnScreen(ctx, info, window) // ★ 直接绑到 window
 *   OH_Drawing_SurfaceGetCanvas(surface)                // 拿到完整 2D 画布
 *   ...画圆角矩形/路径/文字/图片...
 *   OH_Drawing_SurfaceFlush(surface)                    // 提交出帧
 *
 * 也就是说：**Skia 2D 直接画进编码器的输入 window**，GPU 加速、零拷贝、
 * 文字排版用系统 Typography。这比手写 GL 省掉整个"迷你 UI 框架"。
 * 依据：native_drawing/drawing_surface.h:80（API 16+，本工程 API 26）。
 *
 * ## 线程模型
 *
 *   调用者线程 ──Start()──▶ 渲染线程（本类自有）
 *                              │ 每帧：DrawFrame() + SurfaceFlush()
 *                              ▼
 *                       编码器输入 window ──▶ H.264
 *
 * 渲染线程是**我们自己的线程**，与屏幕显示状态无关 —— 这正是"切后台不掉"的根据。
 *
 * ## 数据来源
 *
 * ArkTS 侧通过 SetState() 推送 HMI 状态（页面/连接/导航/音频）。
 * 状态用「版本号 + 互斥锁」传递，渲染线程只在版本变化时拷贝一次，避免每帧加锁。
 */

#ifndef CARHI_HMI_RENDERER_H
#define CARHI_HMI_RENDERER_H

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <native_drawing/drawing_text_declaration.h>
#include <native_drawing/drawing_types.h>
#include <native_window/external_window.h>

namespace carhi {

/** HMI 页面 */
enum HmiPage {
    HMI_PAGE_HOME = 0,   // 首页：左图标栏 + 中列（导航卡 + 音频卡）+ 右侧地图
    HMI_PAGE_NAVI = 1,   // 导航页：左图标栏 + 纯地图
};

/** 转向类型（决定画哪个箭头） */
enum HmiTurnType {
    HMI_TURN_NONE = 0,
    HMI_TURN_LEFT = 1,
    HMI_TURN_RIGHT = 2,
    HMI_TURN_STRAIGHT = 3,
    HMI_TURN_ARRIVE = 4,
};

/** 导航卡内容 */
struct HmiNaviInfo {
    int32_t turnType = HMI_TURN_RIGHT;
    int32_t distanceM = 0;         // 剩余距离（米）；<0 表示不显示数字
    /**
     * 当前导航段进度 0-100。
     *
     * ★ 语义抄自 CarWith 的 `UCarMapInfo.getProgress()`：渲染成**整张导航卡的
     *   背景填充**（从左往右按比例），这是 CarWith 导航卡最标志性的视觉特征
     *   （`nav_progress_view_1a` + `LinearProgressView`，onDraw 就是
     *   `drawRect(0,0,width*progress/100,height)`）。
     * ≤ 0 不画进度填充；> 100 截断到 100。
     */
    int32_t progress = 0;
    char distanceText[24] = "--";  // 距离显示文本（"300" / "1.2"）
    char distanceUnit[8] = "m";
    char road[64] = "";
    char hint[160] = "";
    char nextHint[128] = "";
};

/** 音频迷你卡内容 */
struct HmiAudioInfo {
    char title[128] = "--";
    char artist[128] = "";
    int32_t positionMs = 0;
    int32_t durationMs = 0;
    int32_t playing = 0;   // 1 = 播放中
};

/** 顶部状态栏（参考 carwith_car_hmi_home.html） */
struct HmiStatusInfo {
    char clock[16] = "01:18";
    /** 信号格数 0-4 */
    int32_t signalBars = 4;
    /** 运营商 / 网络制式文字 */
    char carrier[16] = "5G";
    /** 电量百分比 0-100 */
    int32_t batteryPct = 78;
};

/** 天气卡 */
struct HmiWeatherInfo {
    int32_t tempC = 26;
    char condition[32] = "多云";
    char city[32] = "上海";
    char airQuality[24] = "空气优";
};

/** 通勤 / 到达时间卡 */
struct HmiEtaInfo {
    int32_t minutes = 28;
    char arriveAt[16] = "09:10";
};

/** HMI 全量状态（ArkTS 侧推送） */
struct HmiState {
    int32_t page = HMI_PAGE_HOME;
    HmiNaviInfo navi{};
    HmiAudioInfo audio{};
    HmiStatusInfo status{};     // 顶部状态栏（时间/信号/电量）
    HmiWeatherInfo weather{};   // 天气卡
    HmiEtaInfo eta{};           // 通勤/到达卡
    int32_t connected = 0;
};

/**
 * HMI 渲染器。
 *
 * 生命周期：Start() -> SetState()* -> Stop()；Stop 可重复调用。
 * 线程安全：Start/Stop/SetState 可从任意线程调用。
 */
class HmiRenderer {
public:
    using LogCallback = std::function<void(const std::string &)>;

    HmiRenderer() = default;
    ~HmiRenderer();

    HmiRenderer(const HmiRenderer &) = delete;
    HmiRenderer &operator=(const HmiRenderer &) = delete;

    /**
     * 启动渲染线程。
     *
     * @param window 目标 window —— 传**编码器的输入 surface**（OHNativeWindow*）。
     * @param width  画布宽（像素），需与编码器输入几何一致。
     * @param height 画布高（像素）。
     * @param fps    目标帧率。
     * @param onLog  日志回调（可空）。
     * @return 0 成功；1 GPU(Skia) 表面创建失败且 CPU 回退也不可用；2 线程启动失败
     */
    int32_t Start(OHNativeWindow *window, int32_t width, int32_t height, int32_t fps,
                  LogCallback onLog);

    /** 停止渲染线程并释放全部资源（幂等） */
    void Stop();

    /** 推送 HMI 状态（线程安全，非阻塞） */
    void SetState(const HmiState &state);

    bool IsRunning() const { return running_.load(); }

    /** 已渲染（提交）的帧数，用于诊断 */
    uint64_t FrameCount() const { return frameCount_.load(); }

    /** 最近一次提交是否成功（0 = 成功） */
    int32_t LastFlushCode() const { return lastFlushCode_.load(); }

    /** 是否退化到 CPU 位图后端（GPU 表面建不起来时的兜底） */
    bool UsingCpuBackend() const { return usingCpuBackend_.load(); }

    /**
     * 由上层注入的"CPU 位图后端出帧"回调。
     *
     * CPU 后端下画布是内存位图，渲染完要把像素交给编码器 —— 这里回调出去，
     * 由 CanvasEncoder::PushPixels 走已验证的 GL 上传通路。
     * 签名：(width, height, rgba) -> 0 成功
     */
    using PresentCpuCallback = std::function<int32_t(int32_t, int32_t, const uint8_t *)>;
    void SetCpuPresenter(PresentCpuCallback cb);

    // -----------------------------------------------------------------------
    // 后端选择 + 自愈（2026-10-14 晚加入）
    //
    // 为什么要它：GPU OnScreen 后端是"未在真机验证过"的一条路。如果它画了但
    // 像素没进编码器（A2 就是这个症状），用户看到的就是**一片黑**，而且不知道
    // 为什么。所以必须有两条腿：
    //   1. 自愈：自己提交了 N 帧、编码器 0 帧输出 → 自动退 CPU 后端。
    //   2. 手动：设置页一键切后端，黑屏时用户自己就能救回来。
    // -----------------------------------------------------------------------

    /** 后端选择 */
    enum Backend {
        BACKEND_AUTO = 0,  // 默认：CPU 位图。GPU OnScreen 绑编码器输入窗口实测只出首帧
                           // （见 hmi_renderer.cpp 的 CreateBackend 注释），故不再默认尝试
        BACKEND_GPU = 1,   // 强制 GPU OnScreen
        BACKEND_CPU = 2,   // 强制 CPU 位图 → GL 上传
    };

    /**
     * 请求切换后端（线程安全，渲染线程下一帧生效）。
     * 传 Backend 枚举值；越界值被忽略。
     */
    void RequestBackend(int32_t backend);

    /** 当前实际后端：0 = GPU OnScreen，1 = CPU 位图 */
    int32_t CurrentBackend() const { return currentBackend_.load(); }

    /** 是否已发生过自愈（GPU→CPU 自动降级）。诊断用 */
    bool SelfHealed() const { return selfHealed_.load(); }

    /**
     * 由上层注入「编码器累计输出帧数」探针 —— 自愈的判据来源。
     *
     * 不注入则自愈功能关闭（只按启动时的探测结果选后端）。
     */
    using OutputFramesCallback = std::function<uint64_t()>;
    void SetOutputFramesProbe(OutputFramesCallback cb);

    /**
     * 由上层注入「释放编码器侧 EGL/GL 资源」的回调。
     *
     * 切到 GPU 后端之前会先调它 —— 否则 CPU 后端留在编码器 window 上的
     * EGLSurface 会和 GPU 表面抢同一个 window。不注入则该步骤跳过。
     */
    using ReleaseGlCallback = std::function<void()>;
    void SetGlReleaser(ReleaseGlCallback cb);

    // -----------------------------------------------------------------------
    // 离线自检（不需要编码器、不需要 window、不启渲染线程）
    //
    // 为什么需要：整条「自绘 → 编码器 → 推流」链路的验证被编码器卡住了。
    // 有些环境（典型是模拟器）**根本没有视频编码器**（AVC/HEVC 全不可用），
    // 于是什么都验不了。但"画得出来吗"这件事跟编码器无关 —— 它只需要
    // Skia 的 CPU 位图后端，并且是**同步**的，结果能直接返回。
    //
    // ★ 为什么不在 native 侧落 PNG：`native_drawing` 里**没有图像编码接口**
    //   （无 EncodeToFile / ImageFormat / PNG 符号，`native_image/` 也只有
    //   graphic_error_code.h + native_image.h，没有 packer）。所以这里只把
    //   渲染结果以**回调**形式交出去（RGBA8888 裸像素），由 ArkTS 侧用 image kit
    //   落盘 —— 那条路是官方既有能力，不需要我们连编码器一起赌上。
    // -----------------------------------------------------------------------

    /** 自检结果（同步返回，不含编码器） */
    struct SelfCheckResult {
        int32_t width = 0;
        int32_t height = 0;
        /** 每页 draw 的耗时（毫秒） */
        double homeMs = 0;
        double navMs = 0;
        /** 两页像素是否都交付成功（0 = 成功）*/
        int32_t giveHomeCode = -1;
        int32_t giveNavCode = -1;
        /** 非 0 表示自检本身失败（后端建不起来、字体集合失败等） */
        int32_t failCode = 0;
        /** 诊断用：CPU 位图后端是否真的建起来了（1 = 是） */
        int32_t cpuBackendOk = 0;
    };

    /**
     * 每页渲染完成后回调一次，把裸像素交出去。
     *
     * ⚠ 必须在回调返回前把数据拷走 —— 底层缓冲在下一次自检/析构后就没了。
     *
     * @param name      页名（"home" / "nav"）
     * @param pixels    RGBA8888 裸像素，长度 = width*height*4
     * @param width     宽
     * @param height    高
     * @param drawMs    本页绘制耗时（毫秒）
     */
    using SelfCheckPageCallback = std::function<void(
        const char *name, const uint8_t *pixels, int32_t width, int32_t height,
        double drawMs)>;

    /**
     * 跑一次离线自检：用 CPU 位图后端把首页与导航页各画一遍。
     *
     * **不碰编码器、不起渲染线程**，所以「模拟器没有视频编码器」也照样能验。
     *
     * @param width/height 画布尺寸
     * @param cb 每页像素回调；为空则只计耗时、不交付像素
     * @return 自检结果
     */
    SelfCheckResult RunSelfCheck(int32_t width, int32_t height,
                                 SelfCheckPageCallback cb);

private:
    void ThreadMain();
    bool CreateBackend();
    void DestroyBackend();
    /** 只建 GPU OnScreen 后端；成功 true */
    bool CreateGpuBackend();
    /** 只建 CPU 位图后端；成功 true */
    bool CreateCpuBackend();
    /** 销毁现有后端并重建为指定后端；wantCpu=true 走 CPU */
    bool RebuildBackend(bool wantCpu);
    void DrawFrame(OH_Drawing_Canvas *canvas, const HmiState &st);
    void RenderOnce();

    // ---- 绘制原语 ----
    /** 左侧图标栏；page 决定哪个图标处于激活态（0 首页 / 1 导航） */
    void DrawRail(OH_Drawing_Canvas *c, int32_t page);
    void DrawNavCard(OH_Drawing_Canvas *c, const HmiState &st, double x, double y, double w, double h);
    void DrawAudioCard(OH_Drawing_Canvas *c, const HmiState &st, double x, double y, double w, double h);
    void DrawMap(OH_Drawing_Canvas *c, double x, double y, double w, double h);

    // ---- 首页（参考 carwith_car_hmi_home.html 设计稿，2026-10-15 重做）----
    void DrawHomePage(OH_Drawing_Canvas *c, const HmiState &st);
    /** 顶部状态栏：左时间 / 右信号 + 电量 */
    void DrawStatusBar(OH_Drawing_Canvas *c, const HmiState &st, double x, double y,
                       double w, double h);
    /** 左侧竖排 Dock：6 个图标（主页/语音/地图/音乐/通话/更多），docked 高亮 */
    void DrawDock(OH_Drawing_Canvas *c, double x, double y, double w, double h);
    /** 中间导航大卡：导航中 pill + 路线缩略图 + 「前方 300m 右转」+ 目的地 */
    void DrawHomeNavCard(OH_Drawing_Canvas *c, const HmiState &st, double x, double y,
                         double w, double h);
    /** 右侧卡片：音乐（封面+曲名+进度条）/ 天气 / 通勤 */
    void DrawMusicCard(OH_Drawing_Canvas *c, const HmiState &st, double x, double y,
                       double w, double h);
    void DrawWeatherCard(OH_Drawing_Canvas *c, const HmiState &st, double x, double y,
                         double w, double h);
    void DrawEtaCard(OH_Drawing_Canvas *c, const HmiState &st, double x, double y,
                     double w, double h);

    // ---- 导航页（参考小米 CarWith 版式）----
    void DrawNaviPage(OH_Drawing_Canvas *c, const HmiState &st);
    /** 导航引导卡：进度条铺满整卡背景 + 左侧大转向图标 + 距离/动作/路名 */
    void DrawNaviGuideCard(OH_Drawing_Canvas *c, const HmiState &st, double x, double y,
                           double w, double h);
    /** 底部下一步提示条 */
    void DrawNaviNextBar(OH_Drawing_Canvas *c, const HmiState &st, double x, double y,
                         double w, double h);
    /** 右下角"回到当前位置"FAB */
    void DrawNaviFab(OH_Drawing_Canvas *c, double cx, double cy, double r);

    void Log(const std::string &msg);

private:
    // 画布尺寸 / 帧率
    int32_t width_ = 1280;
    int32_t height_ = 720;
    int32_t fps_ = 30;

    std::atomic<bool> running_{false};
    std::atomic<bool> threadExited_{false};
    std::atomic<uint64_t> frameCount_{0};
    std::atomic<int32_t> lastFlushCode_{0};
    std::atomic<bool> usingCpuBackend_{false};
    std::atomic<bool> stateDirty_{true};

    /** 上层请求的后端（Backend 枚举）；渲染线程消费 */
    std::atomic<int32_t> requestedBackend_{BACKEND_AUTO};
    /** 当前实际后端：0 = GPU，1 = CPU */
    std::atomic<int32_t> currentBackend_{0};
    /** 是否已自愈降级过 */
    std::atomic<bool> selfHealed_{false};

    std::thread thread_;
    std::mutex lock_;                 // 保护 state_ / window_ / 回调
    std::condition_variable readyCv_;
    std::mutex readyLock_;
    bool ready_ = false;
    int32_t startResult_ = 0;

    OHNativeWindow *window_ = nullptr;

    HmiState state_{};
    LogCallback onLog_;
    PresentCpuCallback presentCpu_;
    OutputFramesCallback outputFramesProbe_;
    ReleaseGlCallback releaseGl_;

    // ---- 后端资源（只在渲染线程访问）----
    OH_Drawing_GpuContext *gpuCtx_ = nullptr;
    OH_Drawing_Surface *surface_ = nullptr;
    OH_Drawing_Canvas *canvas_ = nullptr;      // OnScreen 后端：由 surface 提供，不销毁

    // CPU 回退后端
    std::vector<uint8_t> cpuPixels_;
    OH_Drawing_Bitmap *cpuBitmap_ = nullptr;
    OH_Drawing_Canvas *cpuCanvas_ = nullptr;

    // ---- 共享资源 ----
    OH_Drawing_FontCollection *fontCollection_ = nullptr;
};

} // namespace carhi

#endif // CARHI_HMI_RENDERER_H
