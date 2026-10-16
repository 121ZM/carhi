/*
 * CarHi 画面编码管线（Native）—— 路线 A：自绘，不走录屏
 *
 * ## 与录屏方案的根本区别
 *
 *   录屏（旧）：OH_AVScreenCapture ──Surface──▶ OH_VideoEncoder ──▶ H.264
 *   自绘（现）：我们自己画 ──────────Surface──▶ OH_VideoEncoder ──▶ H.264
 *
 *   编码器那一段**完全一样**（Configure / GetSurface / Prepare / Start）。
 *   差别只在「往那个 Surface 上写什么」：
 *     - 旧方案：交给系统采集器去写（所以受采集管线的一切约束）
 *     - 新方案：我们自己写（所以切后台/息屏/旋转都不再是问题）
 *
 * ## 为什么这样能解决"切应用就断"
 *
 *   录屏方案里，Surface 的内容由**系统采集器**生产。系统采集器跟着屏幕
 *   显示状态走 —— 切后台、息屏、旋转都会让它停摆或重建。
 *   自绘方案里，Surface 的内容由**我们自己的渲染循环**生产，跟屏幕状态无关，
 *   只跟我们的进程活着与否有关（这由长时任务保证）。
 *
 * ## 渲染路径的两种画法（★ 2026-10-13 查证后修正）
 *
 *   ★ 重要更正：**「把 XComponent 的 surfaceId 交给编码器」这条 A2 路数不成立**。
 *     编码器（消费者）持有自己的输入 surface（OH_VideoEncoder_GetSurface），
 *     XComponent（生产者）持有自己的 surface，两者是两口井，鸿蒙**没有任何
 *     API 能把它们连通**。实测结果：编码器起来了，但一帧输入都收不到。
 *
 *   Surface 模式的正确数据流（官方口径）：
 *     **「编码器提供 Surface，生产者直接写入，编码器直接读取」**
 *     即：**生产者必须往编码器的输入 surface 里画**。
 *
 *   由此，真实可行的两种画法：
 *   A1. Native 层 EGL + OpenGL，**直接画进编码器的输入 surface**。
 *       性能最好、零拷贝；代价是界面全靠手写 GL。
 *   β.  ArkUI 正常渲染 XComponent，再由 native 每帧把它**拷进**编码器
 *       surface。保留 ArkUI 的开发效率；代价是每帧一次拷贝。
 *
 *   两者的共同地基都是：**能往编码器的输入 surface 里写并出帧**。
 *   这一点由 `pipeline_probe.cpp` 独立验证。
 *
 *   本类的职责相应调整为：**管好编码器，并把它的输入 surface 暴露出去**
 *   （见 `GetInputWindow`），由上层（GL 或拷贝逻辑）往里画。
 */

#ifndef CARHI_CANVAS_ENCODER_H
#define CARHI_CANVAS_ENCODER_H

#include <atomic>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>

#include <EGL/egl.h>
#include <GLES3/gl3.h>

#include <multimedia/player_framework/native_avcodec_videoencoder.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_avcodec_base.h>

namespace carhi {

/** 一帧编码产物（H.264 Annex-B 裸流，无容器封装） */
struct EncodedFrame {
    const uint8_t *data;
    int32_t size;
    int64_t pts;        // 微秒
    bool keyFrame;
};

/**
 * 编码参数。
 *
 * ★ 路线 A 下这些值**由我们自己决定**（不再迁就手机物理屏）。
 *   默认取 1280×720 —— 通用 16:9，车机侧自行缩放显示。
 */
struct EncoderParams {
    int32_t width = 1280;
    int32_t height = 720;
    int32_t frameRate = 30;
    int32_t bitrate = 4000000;   // bit/s
    int32_t iFrameIntervalMs = 2000;
};

/** Start() 的失败阶段编码（供上层区分失败原因） */
enum StartStage {
    STAGE_OK = 0,
    STAGE_CREATE_CODEC_FAILED = 1,
    STAGE_CONFIGURE_FAILED = 2,
    STAGE_GET_SURFACE_FAILED = 3,
    STAGE_REGISTER_CALLBACK_FAILED = 4,
    STAGE_PREPARE_FAILED = 5,
    STAGE_START_CODEC_FAILED = 6,
    STAGE_ATTACH_SURFACE_FAILED = 7,
};

/**
 * 画面编码管线。
 *
 * 生命周期：Start*() -> ... -> Stop()，Stop 可重复调用。
 * 线程模型：Start/Stop 在调用者线程；编码输出回调在编解码器线程，
 *          由上层（napi_init）负责转投到 JS 线程。
 */
class CanvasEncoder {
public:
    using FrameCallback = std::function<void(const EncodedFrame &frame)>;
    using ErrorCallback = std::function<void(int32_t code, const std::string &msg)>;
    using LogCallback = std::function<void(const std::string &msg)>;

    CanvasEncoder() = default;
    ~CanvasEncoder();

    CanvasEncoder(const CanvasEncoder &) = delete;
    CanvasEncoder &operator=(const CanvasEncoder &) = delete;

    /**
     * 启动编码器，并把它绑定到一个**外部提供的 surface**。
     *
     * @param surfaceId 外部 Surface 的 id（如 XComponent 的 surfaceId）。
     *                  传 0 表示"只建编码器、暂不绑 surface"（此时不产帧）。
     * @return STAGE_OK 成功；其余见 enum StartStage
     */
    int32_t Start(uint64_t surfaceId, const EncoderParams &params,
                  FrameCallback onFrame, ErrorCallback onError, LogCallback onLog);

    /** 运行中补绑/换绑 surface（如 XComponent 晚于编码器就绪时） */
    int32_t AttachSurface(uint64_t surfaceId);

    /** 停止并释放全部资源（幂等） */
    void Stop();

    /** 请求立即编一个 I 帧（车机刚连上时用，避免等一个 GOP） */
    void RequestKeyFrame();

    /** 运行中动态调整帧率（车机 98316）。不重建管线。@return 0 成功 */
    int32_t SetFrameRate(int32_t frameRate);

    bool IsRunning() const { return running_.load(); }

    /**
     * 编码器**累计输出的帧数**。
     *
     * 用途：自绘渲染器用它做「后端自愈」判据 —— 如果自己提交了 N 帧、
     * 而编码器一帧都没吐出来，说明画面根本没进编码器（A2 就是这个症状），
     * 必须换后端，而不是傻等。
     */
    uint32_t OutputFrameCount() const { return outputFrameCount_.load(); }

    /** 编码器实际输出的宽高（可能与请求值不同，编码器会按对齐调整） */
    int32_t EncodedWidth() const { return encodedWidth_.load(); }
    int32_t EncodedHeight() const { return encodedHeight_.load(); }

    /**
     * ★ 暴露编码器**自己的输入 surface**（OHNativeWindow*）。
     *
     * 这是唯一能往编码器里送画面的入口：
     *   - A1：在上面的 surfaceId 建 EGLSurface，用 GL 画
     *   - β ：把 XComponent 的内容拷进这块 surface
     *
     * @param out 输出参数，成功时写入非空指针
     * @return true 成功。注意返回的是**内部引用**，调用方不要销毁它。
     */
    bool GetInputWindow(OHNativeWindow **out);

    /**
     * 编码器输入 surface 的 surfaceId（内部对 GetInputWindow 的结果套
     * OH_NativeWindow_GetSurfaceId）。0 表示未就绪。建 EGLSurface 用这个。
     */
    uint64_t InputSurfaceId() const;

    /**
     * ★ 前台推流通路：把一张 RGBA 位图画进编码器输入 surface。
     *
     * 数据流：ArkUI getSync 截图 PixelMap → AccessPixels 拿到地址 → 本函数
     *   → EGL 纹理上传 → 全屏 quad 绘制 → eglSwapBuffers → 编码器出帧。
     *
     * 首次调用会懒初始化 EGL（display/config/context/window surface）。
     * 宽高比不一致时按「居中裁剪后拉伸」处理（后续可改为黑边）。
     *
     * @param w 位图宽（像素）
     * @param h 位图高（像素）
     * @param rgba 位图内存（RGBA8888，stride 按 w*4 处理）
     * @return 0 成功；非 0 失败（EGL/GL 错误码见日志）
     */
    int32_t PushPixels(int32_t w, int32_t h, const uint8_t *rgba);

    /** 供外部把帧"推"进编码器（若将来不用 Surface 而用 buffer 模式） */
    int32_t PushFrame(const uint8_t *data, int32_t size, int64_t pts);

    /**
     * 释放 PushPixels 懒建的 EGL / GL 资源（幂等）。
     *
     * ★ 为什么需要它：自绘渲染器在「CPU 位图后端 ↔ GPU OnScreen 后端」之间
     *   切换时，CPU 后端会在编码器 window 上建 EGLSurface；若不先解绑，
     *   GPU 表面会和它抢同一个 window，导致建面失败或画面错乱。
     *
     * ⚠ **必须在当初调用 PushPixels 的那个线程上调用**（EGL context 与线程绑定）。
     */
    void ReleaseGlResources();

private:
    static void OnCodecError(OH_AVCodec *codec, int32_t errorCode, void *userData);
    static void OnStreamChanged(OH_AVCodec *codec, OH_AVFormat *format, void *userData);
    static void OnNeedInputBuffer(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData);
    static void OnNewOutputBuffer(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData);

    void HandleNewOutputBuffer(uint32_t index, OH_AVBuffer *buffer);
    void EmitError(int32_t code, const std::string &msg);
    void ReleaseCodec();

private:
    std::atomic<bool> running_{false};
    std::atomic<bool> codecStarted_{false};
    std::atomic<int32_t> encodedWidth_{0};
    std::atomic<int32_t> encodedHeight_{0};
    std::atomic<bool> forceKeyFrame_{false};

    /** 编码器累计输出帧数（诊断 + 自绘后端自愈判据） */
    std::atomic<uint32_t> outputFrameCount_{0};

    EncoderParams params_{};
    FrameCallback onFrame_;
    ErrorCallback onError_;
    LogCallback onLog_;

    OH_AVCodec *codec_ = nullptr;
    OHNativeWindow *encoderSurface_ = nullptr;
    /**
     * 外部画布 Surface 的引用（由 AttachSurface 从 surfaceId 建立）。
     * 持有引用的目的是防止在我们还在往它编码时被外部销毁。
     */
    OHNativeWindow *canvasSurface_ = nullptr;

    // ---- EGL（PushPixels 前台推流通路）----
    EGLDisplay eglDpy_ = EGL_NO_DISPLAY;
    EGLContext eglCtx_ = EGL_NO_CONTEXT;
    EGLSurface eglSurf_ = EGL_NO_SURFACE;
    GLuint tex_ = 0;
    GLuint prog_ = 0;
    bool eglReady_ = false;
    int32_t lastTexW_ = 0;
    int32_t lastTexH_ = 0;

    /** 懒初始化 EGL（在编码器自己的输入 surface 上）。成功后 eglReady_=true */
    bool EnsureEgl();

    /** 释放全部 EGL 资源（幂等） */
    void DestroyEgl();

    mutable std::mutex lock_;   // mutable：InputSurfaceId() 等 const 方法也要加锁
};

} // namespace carhi

#endif // CARHI_CANVAS_ENCODER_H
