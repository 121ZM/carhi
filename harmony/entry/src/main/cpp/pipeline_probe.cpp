/*
 * 编码管线最小验证探针 —— 实现
 *
 * 验证目标：证明「往编码器自己的输入 surface 里画 → 编码器出帧」这条链路成立。
 * 这是路线 A 唯一可行的机制（A2 的 surfaceId 直连已证伪）。
 *
 * 关键 API 依据：
 *   - OH_VideoEncoder_GetSurface(codec, &win)          // 编码器输入 surface
 *   - OH_NativeWindow_GetSurfaceId(win, &id)           // 给它建 EGLSurface 用
 *   - eglGetPlatformDisplay(EGL_PLATFORM_OHOS_KHR,...)  // 鸿蒙 EGL 平台
 */

#include "pipeline_probe.h"

#include <cinttypes>
#include <thread>
#include <chrono>
#include <atomic>
#include <mutex>

#include <hilog/log.h>
#include <native_window/external_window.h>
#include <native_buffer/buffer_common.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>

#include "canvas_encoder.h"

#define LOG_DOMAIN 0x0001
#define LOG_TAG "CarHiProbe"
#define PLOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)

// 鸿蒙特有的 EGL 平台枚举（见 eglext.h 里的 OHOS 扩展）
#ifndef EGL_PLATFORM_OHOS_KHR
#define EGL_PLATFORM_OHOS_KHR 0x34E0
#endif
#ifndef EGL_NATIVE_BUFFER_OHOS
#define EGL_NATIVE_BUFFER_OHOS 0x34E1
#endif

namespace carhi {
namespace {

/** EGL 错误码打成「十进制(十进制) / 十六进制」双格式，免得看错 */
std::string EglErrText(EGLint e) {
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%d / 0x%X", static_cast<int>(e),
                  static_cast<unsigned>(e));
    return std::string(buf);
}

/** 探针运行期的共享状态（编码器回调线程 → 主线程） */
struct ProbeState {
    std::atomic<int32_t> outputFrames{0};
    std::atomic<int64_t> firstPts{-1};
    std::atomic<int32_t> lastFlags{0};
    std::atomic<int32_t> lastSize{0};
};

ProbeState *g_state = nullptr;   // 探针期间临时挂上，编码器回调里读

} // namespace

ProbeResult RunPipelineProbe(int32_t width, int32_t height, int32_t seconds,
                             const std::function<void(const std::string &)> &log) {
    ProbeResult r;
    auto say = [&](const std::string &s) {
        PLOGI("%{public}s", s.c_str());
        if (log) { log(s); }
    };

    // 尺寸规整：YUV 4:2:0 要求偶数
    width = width - (width % 2);
    height = height - (height % 2);
    if (width < 128) { width = 1280; }
    if (height < 128) { height = 720; }
    if (seconds < 1) { seconds = 2; }
    if (seconds > 15) { seconds = 15; }

    say("=== 编码管线最小验证开始 ===");
    say("目标尺寸 " + std::to_string(width) + "x" + std::to_string(height)
        + "，持续 " + std::to_string(seconds) + "s");

    // ---------------------------------------------------------------
    // 0. 准备状态
    // ---------------------------------------------------------------
    ProbeState state;
    g_state = &state;

    // ---------------------------------------------------------------
    // 1. 建编码器（复用 CanvasEncoder，但**不**传 surfaceId —— 它的输入
    //    surface 由 GetSurface 内部拿，我们回头取它的 id 来画）
    // ---------------------------------------------------------------
    CanvasEncoder encoder;
    EncoderParams params{};
    params.width = width;
    params.height = height;
    params.frameRate = 30;
    params.bitrate = 6000000;
    params.iFrameIntervalMs = 1000;

    auto onFrame = [&state](const EncodedFrame &f) {
        int32_t n = state.outputFrames.fetch_add(1) + 1;
        if (n == 1) {
            state.firstPts.store(f.pts);
            state.lastFlags.store(static_cast<int32_t>(f.keyFrame));
            state.lastSize.store(f.size);
        }
    };
    auto onError = [&say](int32_t code, const std::string &msg) {
        say("编码器错误 code=" + std::to_string(code) + " " + msg);
    };
    auto onLog = [&say](const std::string &msg) { say(msg); };

    // surfaceId 传 0：表示「不要外部画布」，AttachSurface 不会被调用
    int32_t stage = encoder.Start(0, params, onFrame, onError, onLog);
    if (stage != 0) {
        r.stage = "startEncoder";
        r.error = "编码器启动失败 stage=" + std::to_string(stage);
        say("✗ " + r.error);
        g_state = nullptr;
        return r;
    }
    r.encWidth = encoder.EncodedWidth();
    r.encHeight = encoder.EncodedHeight();
    say("✓ 编码器已启动 " + std::to_string(r.encWidth) + "x" + std::to_string(r.encHeight));
    r.stage = "encoder_started";

    // ---------------------------------------------------------------
    // 2. 取编码器输入 surface 的 surfaceId
    //    ★ 只有暴露了「输入 surface 的 id」，才能在上面建 EGLSurface。
    // ---------------------------------------------------------------
    OHNativeWindow *encWin = nullptr;
    if (!encoder.GetInputWindow(&encWin) || encWin == nullptr) {
        r.stage = "get_input_window";
        r.error = "取不到编码器输入 surface 的 NativeWindow";
        say("✗ " + r.error);
        encoder.Stop();
        g_state = nullptr;
        return r;
    }

    uint64_t encSurfaceId = 0;
    int32_t sidRet = OH_NativeWindow_GetSurfaceId(encWin, &encSurfaceId);
    if (sidRet != 0 || encSurfaceId == 0) {
        r.stage = "get_surface_id";
        r.error = "OH_NativeWindow_GetSurfaceId 失败 ret=" + std::to_string(sidRet);
        say("✗ " + r.error);
        encoder.Stop();
        g_state = nullptr;
        return r;
    }
    r.surfaceIdOk = 1;
    r.surfaceId = encSurfaceId;
    say("✓ 编码器输入 surface id = " + std::to_string(encSurfaceId));
    r.stage = "got_surface_id";

    // ---------------------------------------------------------------
    // 2.5 ★ 给编码器输入 surface 设好 buffer 几何与像素格式
    //
    //     实测教训（probe2）：不设 geometry 直接建 EGLSurface 会「建成功、
    //     swap 失败 EGL_BAD_ALLOC(0x3003)」—— 因为这块 window 没有可分配的
    //     后备 buffer。编码器要的是 YUV420（NV12/NV21）格式的图形缓冲。
    // ---------------------------------------------------------------
    {
        int32_t gerr = OH_NativeWindow_NativeWindowHandleOpt(
            encWin, SET_BUFFER_GEOMETRY, width, height);
        say("SET_BUFFER_GEOMETRY(" + std::to_string(width) + "x" + std::to_string(height)
            + ") ret=" + std::to_string(gerr));

        // ★ 格式必须与 EGL config 匹配，否则 eglCreateWindowSurface 报
        //   EGL_BAD_MATCH(0x3009)。EGL 渲染的是 RGBA，所以这里也设 RGBA_8888。
        //   （试过 YCBCR_420_SP → 直接 BAD_MATCH，见 probe3 记录。）
        int32_t ferr = OH_NativeWindow_NativeWindowHandleOpt(
            encWin, SET_FORMAT, NATIVEBUFFER_PIXEL_FMT_RGBA_8888);
        say("SET_FORMAT(RGBA_8888) ret=" + std::to_string(ferr));
    }

    // ---------------------------------------------------------------
    // 3. EGL 初始化 + 在编码器 surface 上建 EGLSurface
    // ---------------------------------------------------------------
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLConfig config = nullptr;
    EGLContext context = EGL_NO_CONTEXT;
    EGLSurface eglSurface = EGL_NO_SURFACE;

    // 3.1 取 EGL display。鸿蒙推荐用 platform display
    //     （eglGetPlatformDisplay 是 EGL 1.5 核心函数，头里直接有声明）。
    display = eglGetPlatformDisplay(EGL_PLATFORM_OHOS_KHR, EGL_DEFAULT_DISPLAY, nullptr);
    if (display == EGL_NO_DISPLAY) {
        // 兜底：老实现回落默认
        say("EGL: platform display 失败，回落 eglGetDisplay");
        display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    } else {
        say("EGL: 已取到 EGL_PLATFORM_OHOS_KHR display");
    }
    if (display == EGL_NO_DISPLAY) {
        r.stage = "egl_display";
        r.error = "拿不到 EGLDisplay";
        say("✗ " + r.error);
        encoder.Stop();
        g_state = nullptr;
        return r;
    }

    EGLint major = 0;
    EGLint minor = 0;
    if (eglInitialize(display, &major, &minor) != EGL_TRUE) {
        r.stage = "egl_initialize";
        r.error = "eglInitialize 失败 (0x" + std::to_string(eglGetError()) + ")";
        say("✗ " + r.error);
        encoder.Stop();
        g_state = nullptr;
        return r;
    }
    say("EGL " + std::to_string(major) + "." + std::to_string(minor) + " 已初始化");

    // 3.2 选 config：要能渲染到 native window（EGL_WINDOW_BIT）。
    //     ★ 用 EGL_OPENGL_ES2_BIT 而不是 ES3_BIT —— 实测本机 EGL 只报 1.4，
    //       ES3_BIT（来自 EGL_KHR_create_context）在这种 display 上可能被拒。
    //       ES2 config 建 ES3 context 是允许的（向后兼容）。
    say("[步骤] eglChooseConfig...");
    const EGLint cfgAttrs[] = {
        EGL_SURFACE_TYPE,    EGL_WINDOW_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_RED_SIZE,        8,
        EGL_GREEN_SIZE,      8,
        EGL_BLUE_SIZE,       8,
        EGL_ALPHA_SIZE,      8,
        EGL_NONE
    };
    EGLint numConfig = 0;
    if (eglChooseConfig(display, cfgAttrs, &config, 1, &numConfig) != EGL_TRUE || numConfig < 1) {
        r.stage = "egl_choose_config";
        r.error = "eglChooseConfig 失败 (0x" + std::to_string(eglGetError()) + ")";
        say("✗ " + r.error);
        eglTerminate(display);
        encoder.Stop();
        g_state = nullptr;
        return r;
    }
    say("[步骤] eglChooseConfig OK");

    // 3.3 建 context（先试 ES3，失败退 ES2）
    say("[步骤] eglCreateContext...");
    const EGLint ctxAttrs3[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    context = eglCreateContext(display, config, EGL_NO_CONTEXT, ctxAttrs3);
    if (context == EGL_NO_CONTEXT) {
        say("ES3 context 失败，退 ES2");
        const EGLint ctxAttrs2[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
        context = eglCreateContext(display, config, EGL_NO_CONTEXT, ctxAttrs2);
    }
    if (context == EGL_NO_CONTEXT) {
        r.stage = "egl_create_context";
        r.error = "eglCreateContext 失败 (0x" + std::to_string(eglGetError()) + ")";
        say("✗ " + r.error);
        eglTerminate(display);
        encoder.Stop();
        g_state = nullptr;
        return r;
    }
    say("[步骤] eglCreateContext OK");

    // 3.4 ★ 关键一步：用编码器 surface 建 EGLSurface。
    //     ★ 实测教训：把 surfaceId 直接 reinterpret_cast 成 EGLNativeWindowType
    //       会**让进程直接挂掉**（无异常、无 crash 日志、ps 里进程消失）。
    //       鸿蒙要传的是 **OHNativeWindow\*** 指针（EncWin），不是 id 数值。
    say("[步骤] eglCreateWindowSurface(encWin)...");
    const EGLint surfAttrs[] = {EGL_NONE};
    eglSurface = eglCreateWindowSurface(
        display, config, reinterpret_cast<EGLNativeWindowType>(encWin), surfAttrs);
    EGLint e1 = eglGetError();
    say("EGLSurface 结果："
        + std::string(eglSurface != EGL_NO_SURFACE ? "成功" : "失败")
        + " err=0x" + std::to_string(e1));

    if (eglSurface == EGL_NO_SURFACE) {
        r.stage = "egl_create_surface";
        r.error = "eglCreateWindowSurface 全部形态失败";
        say("✗ " + r.error);
        eglDestroyContext(display, context);
        eglTerminate(display);
        encoder.Stop();
        g_state = nullptr;
        return r;
    }
    r.eglOk = 1;
    r.eglSurfaceOk = 1;
    r.stage = "egl_surface_created";

    say("[步骤] eglMakeCurrent...");
    if (eglMakeCurrent(display, eglSurface, eglSurface, context) != EGL_TRUE) {
        r.stage = "egl_make_current";
        r.error = "eglMakeCurrent 失败 (0x" + std::to_string(eglGetError()) + ")";
        say("✗ " + r.error);
        eglDestroySurface(display, eglSurface);
        eglDestroyContext(display, context);
        eglTerminate(display);
        encoder.Stop();
        g_state = nullptr;
        return r;
    }
    say("✓ EGLSurface 已建立并 current —— 现在开始往编码器 surface 画");
    r.stage = "drawing";

    // GL 版本（诊断；也能确认 context 真的可用）
    say(std::string("GL_VERSION=") + reinterpret_cast<const char *>(glGetString(GL_VERSION)));

    // ---------------------------------------------------------------
    // 4. 画 N 秒：每帧换颜色 + eglSwapBuffers
    //    颜色循环能让我们在车机/截图里一眼看出「帧真的在动」。
    // ---------------------------------------------------------------
    const int32_t fps = 30;
    const int32_t totalFrames = seconds * fps;
    const auto frameInterval = std::chrono::microseconds(1000000 / fps);

    for (int32_t i = 0; i < totalFrames; ++i) {
        auto t0 = std::chrono::steady_clock::now();

        // 颜色循环：红→绿→蓝→黄……
        float phase = static_cast<float>(i % 90) / 90.0f;
        float rd = (i / 30) % 3 == 0 ? 1.0f : 0.1f;
        float gr = (i / 30) % 3 == 1 ? 1.0f : 0.1f;
        float bl = (i / 30) % 3 == 2 ? 1.0f : 0.1f;

        glViewport(0, 0, width, height);
        glClearColor(rd * (0.5f + 0.5f * phase), gr * (0.5f + 0.5f * phase),
                     bl * (0.5f + 0.5f * phase), 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);

        if (i == 0) {
            say("[步骤] 首帧 glClear 完成，准备 eglSwapBuffers...");
        }
        EGLBoolean swapped = eglSwapBuffers(display, eglSurface);
        if (swapped == EGL_TRUE) {
            r.swapCount++;
        } else if (i < 3) {
            say("eglSwapBuffers 失败 err=" + EglErrText(eglGetError()));
        }

        if (i == 0 || i == 29 || i == 59 || i == totalFrames - 1) {
            say("画第 " + std::to_string(i + 1) + " 帧：swap=" + std::to_string(r.swapCount)
                + " 编码器已出帧=" + std::to_string(state.outputFrames.load()));
        }

        // 给编码器留出消费时间
        std::this_thread::sleep_for(frameInterval);
        (void)t0;
    }

    // 等编码器把尾帧吐完
    std::this_thread::sleep_for(std::chrono::milliseconds(600));

    // ---------------------------------------------------------------
    // 5. 收尾统计
    // ---------------------------------------------------------------
    r.outputFrames = state.outputFrames.load();
    r.firstOutputPts = state.firstPts.load();
    r.ok = (r.outputFrames > 0);

    say("=== 验证结束 ===");
    say("喂进去(swap)=" + std::to_string(r.swapCount)
        + "，编码器吐出=" + std::to_string(r.outputFrames)
        + (r.firstOutputPts >= 0 ? ("，首帧 pts=" + std::to_string(r.firstOutputPts)) : ""));
    if (r.ok) {
        say("✅ 机制成立：往编码器输入 surface 画 → 能出帧。A1 / β 两条路地基都通。");
    } else {
        say("❌ 机制不通：画了 " + std::to_string(r.swapCount)
            + " 帧但编码器一帧没出，需换思路。");
    }

    // ---------------------------------------------------------------
    // 6. 清理
    // ---------------------------------------------------------------
    eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroySurface(display, eglSurface);
    eglDestroyContext(display, context);
    eglTerminate(display);
    encoder.Stop();
    g_state = nullptr;

    r.stage = "done";
    return r;
}

} // namespace carhi
