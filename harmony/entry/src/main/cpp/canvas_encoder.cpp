/*
 * CarHi 画面编码管线实现（路线 A：自绘，不走录屏）
 *
 * 见 canvas_encoder.h 头注说明设计意图。
 */

#include "canvas_encoder.h"

#include <cinttypes>

#include <hilog/log.h>
#include <native_window/external_window.h>
#include <EGL/egl.h>
#include <GLES3/gl3.h>

#define LOG_DOMAIN 0x0001
#define LOG_TAG "CarHiNative"
#define LOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define LOGW(...) OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)

namespace carhi {

CanvasEncoder::~CanvasEncoder() {
    Stop();
}

int32_t CanvasEncoder::Start(uint64_t surfaceId, const EncoderParams &params,
                             FrameCallback onFrame, ErrorCallback onError, LogCallback onLog) {
    std::lock_guard<std::mutex> guard(lock_);
    if (codecStarted_.load()) {
        LOGW("encoder already started");
        return STAGE_OK;
    }

    params_ = params;
    onFrame_ = std::move(onFrame);
    onError_ = std::move(onError);
    onLog_ = std::move(onLog);

    // ---------------- 1. 创建编码器 ----------------
    codec_ = OH_VideoEncoder_CreateByMime(OH_AVCODEC_MIMETYPE_VIDEO_AVC);
    if (codec_ == nullptr) {
        // ★ 明确打出"哪个 mime 失败了" —— 模拟器缺 H.264 编码器时就是这里挂，
        //   不打出具体 mime 的话，日志里只有 stage=1，查不出根因。
        //   顺带探一下 H.265，判断是"整个编码器都没有"还是"只缺 AVC"。
        OH_AVCodec *probeHevc = OH_VideoEncoder_CreateByMime(OH_AVCODEC_MIMETYPE_VIDEO_HEVC);
        LOGE("CreateByMime(%{public}s) 失败；HEVC 探测: %{public}s",
             OH_AVCODEC_MIMETYPE_VIDEO_AVC, probeHevc != nullptr ? "可用" : "也不可用");
        if (probeHevc != nullptr) {
            OH_VideoEncoder_Destroy(probeHevc);
        }
        return STAGE_CREATE_CODEC_FAILED;
    }

    OH_AVFormat *format = OH_AVFormat_Create();
    if (format == nullptr) {
        ReleaseCodec();
        return STAGE_CONFIGURE_FAILED;
    }
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_WIDTH, params_.width);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_HEIGHT, params_.height);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_SURFACE_FORMAT);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_FRAME_RATE, params_.frameRate);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_VIDEO_ENCODE_BITRATE_MODE, BITRATE_MODE_CBR);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_BITRATE, params_.bitrate);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_I_FRAME_INTERVAL, params_.iFrameIntervalMs);
    // Baseline：无 B 帧、无 CABAC —— 安卓老车机硬解最稳的组合
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_PROFILE, AVC_PROFILE_BASELINE);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_RANGE_FLAG, 0);
    // 低延迟：投屏场景对时延远比对压缩率敏感
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY, 1);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_VIDEO_ENCODER_ENABLE_B_FRAME, 0);

    OH_AVErrCode err = OH_VideoEncoder_Configure(codec_, format);
    OH_AVFormat_Destroy(format);
    format = nullptr;
    if (err != AV_ERR_OK) {
        ReleaseCodec();
        return STAGE_CONFIGURE_FAILED;
    }

    // 必须在 Configure 之后、Prepare 之前取 Surface
    err = OH_VideoEncoder_GetSurface(codec_, &encoderSurface_);
    if (err != AV_ERR_OK || encoderSurface_ == nullptr) {
        ReleaseCodec();
        return STAGE_GET_SURFACE_FAILED;
    }

    // ★ 给编码器输入 surface 设 buffer 几何（2026-10-14）
    //
    // 为什么必须做：EGL 在它上面建 window surface 时，会按「请求的 buffer 尺寸」
    // 向系统申请内存。若不显式告诉它几何，EGL 会用一个默认/不匹配的尺寸，
    // 结果 eglSwapBuffers 返回 **EGL_BAD_ALLOC(0x3003)** —— 分配不出缓冲区。
    // 实测错误码 12291 就是这个（EGL err=12291）。
    {
        int32_t gw = params_.width;
        int32_t gh = params_.height;
        int32_t gerr = OH_NativeWindow_NativeWindowHandleOpt(
            encoderSurface_, SET_BUFFER_GEOMETRY, gw, gh);
        // 注：不要额外 SET_FORMAT —— 编码器已按它的输入格式要求管好了这块
        //     surface 的格式，外部再改会与编码器期望不一致（曾导致
        //     eglCreateWindowSurface 失败）。几何对了就够了。
        LOGI("编码器输入 surface 几何设为 %{public}dx%{public}d (ret=%{public}d)",
             gw, gh, gerr);
    }

    OH_AVCodecCallback callbacks{};
    callbacks.onError = &CanvasEncoder::OnCodecError;
    callbacks.onStreamChanged = &CanvasEncoder::OnStreamChanged;
    callbacks.onNeedInputBuffer = &CanvasEncoder::OnNeedInputBuffer;
    callbacks.onNewOutputBuffer = &CanvasEncoder::OnNewOutputBuffer;
    err = OH_VideoEncoder_RegisterCallback(codec_, callbacks, this);
    if (err != AV_ERR_OK) {
        ReleaseCodec();
        return STAGE_REGISTER_CALLBACK_FAILED;
    }

    err = OH_VideoEncoder_Prepare(codec_);
    if (err != AV_ERR_OK) {
        ReleaseCodec();
        return STAGE_PREPARE_FAILED;
    }

    err = OH_VideoEncoder_Start(codec_);
    if (err != AV_ERR_OK) {
        ReleaseCodec();
        return STAGE_START_CODEC_FAILED;
    }
    codecStarted_.store(true);
    encodedWidth_.store(params_.width);
    encodedHeight_.store(params_.height);

    LOGI("canvas encoder up: %{public}dx%{public}d@%{public}d bitrate=%{public}d",
         params_.width, params_.height, params_.frameRate, params_.bitrate);

    if (codec_ != nullptr) {
        OH_AVFormat *inFmt = OH_VideoEncoder_GetInputDescription(codec_);
        if (inFmt != nullptr) {
            int32_t iw = 0;
            int32_t ih = 0;
            bool okW = OH_AVFormat_GetIntValue(inFmt, OH_MD_KEY_WIDTH, &iw);
            bool okH = OH_AVFormat_GetIntValue(inFmt, OH_MD_KEY_HEIGHT, &ih);
            LOGI("encoder input description: w=%{public}d h=%{public}d (get ok=%{public}d/%{public}d)",
                 iw, ih, static_cast<int32_t>(okW), static_cast<int32_t>(okH));
            OH_AVFormat_Destroy(inFmt);
        } else {
            LOGW("OH_VideoEncoder_GetInputDescription returned null");
        }
    }

    // ---------------- 2. 绑定外部画布 Surface ----------------
    // 编码器的输入 Surface 已由 GetSurface 拿到（在上面）。
    // 「自绘」的含义是：外部（GL 或 XComponent）会往这个 surface 上画。
    //
    // ★ 当前 A2 骨架：用 surfaceId 换一个 OHNativeWindow 引用，建立"外部画布 →
    //   编码器输入"的关联。两件事：
    //     1) 让外部渲染者知道该往哪块 buffer 画（它用自己的 EGL 绑定这个 id）
    //     2) 这里持有一个引用来防止 surface 被提前回收
    //
    //   注意：**真正把画面像素写进去的是外部渲染者**（GL 或 XComponent）。
    //   本模块只保证"编码器等着收帧、且 geometry 对得上"。
    if (surfaceId != 0) {
        int32_t stage = AttachSurface(surfaceId);
        if (stage != STAGE_OK) {
            ReleaseCodec();
            return stage;
        }
    } else {
        LOGW("no canvas surface attached yet — 不会产帧（等 AttachSurface）");
    }

    running_.store(true);
    if (onLog_) {
        onLog_("画面编码管线已启动");
    }
    return STAGE_OK;
}

int32_t CanvasEncoder::AttachSurface(uint64_t surfaceId) {
    if (codec_ == nullptr || encoderSurface_ == nullptr) {
        return STAGE_ATTACH_SURFACE_FAILED;
    }
    // ※ 注意（2026-10-13 查证）：这个方法**不会**让外部 surface 的画面
    //   流进编码器 —— 鸿蒙没有这种 API。它只能「持有一个外部 surface 的
    //   引用」，用于诊断/兼容旧调用。真正送画面必须往 GetInputWindow()
    //   返回的那块 surface 里写（见 pipeline_probe.cpp）。

    // 用 surfaceId 建一个 OHNativeWindow，作为"外部画布"的引用。
    OHNativeWindow *canvasWin = nullptr;
    int32_t ret = OH_NativeWindow_CreateNativeWindowFromSurfaceId(surfaceId, &canvasWin);
    if (ret != 0 || canvasWin == nullptr) {
        LOGE("CreateNativeWindowFromSurfaceId failed: surfaceId=%{public}" PRIu64 " ret=%{public}d",
             surfaceId, ret);
        return STAGE_ATTACH_SURFACE_FAILED;
    }

    // 告诉这块外部 surface：后续会有 w×h 的 RGBA 帧写进来。
    // 这一步让「画布尺寸」与「编码器输入尺寸」对齐 —— 录屏方案里两者不一致
    // 正是导致编码器一帧都编不出来（code=10）的根因。
    int32_t w = params_.width;
    int32_t h = params_.height;
    int32_t err = OH_NativeWindow_NativeWindowHandleOpt(
        canvasWin, SET_BUFFER_GEOMETRY, w, h);
    if (err != 0) {
        LOGW("SET_BUFFER_GEOMETRY failed: ret=%{public}d (继续，几何由外部渲染者决定)", err);
    }

    LOGI("canvas surface attached: surfaceId=%{public}" PRIu64 " geometry=%{public}dx%{public}d",
         surfaceId, w, h);

    // 引用计数 +1，防止在我们还在用的时候被外部销毁。
    OH_NativeWindow_NativeObjectReference(canvasWin);

    // 记下来供 ReleaseCodec 里释放
    {
        std::lock_guard<std::mutex> guard(lock_);
        if (canvasSurface_ != nullptr) {
            OH_NativeWindow_NativeObjectUnreference(canvasSurface_);
        }
        canvasSurface_ = canvasWin;
    }
    return STAGE_OK;
}

bool CanvasEncoder::GetInputWindow(OHNativeWindow **out) {
    if (out == nullptr) {
        return false;
    }
    *out = nullptr;
    std::lock_guard<std::mutex> guard(lock_);
    if (encoderSurface_ == nullptr || !codecStarted_.load()) {
        return false;
    }
    *out = encoderSurface_;   // 内部引用，调用方不得销毁
    return true;
}

uint64_t CanvasEncoder::InputSurfaceId() const {
    OHNativeWindow *win = nullptr;
    {
        // 只读 encoderSurface_ 指针，加锁保持一致
        std::lock_guard<std::mutex> guard(lock_);
        win = encoderSurface_;
    }
    if (win == nullptr) {
        return 0;
    }
    uint64_t id = 0;
    if (OH_NativeWindow_GetSurfaceId(win, &id) != 0) {
        return 0;
    }
    return id;
}

void CanvasEncoder::Stop() {
    std::lock_guard<std::mutex> guard(lock_);
    DestroyEgl();
    if (!codecStarted_.load() && codec_ == nullptr && canvasSurface_ == nullptr) {
        return;
    }
    ReleaseCodec();
    running_.store(false);
    LOGI("canvas encoder stopped");
}

// ============================================================================
// EGL + PushPixels（前台推流通路）
//
// 数据流：ArkUI 同步截图（~26ms）→ PixelMap 像素（RGBA8888）
//   → 纹理上传 → 全屏 quad 绘制 → eglSwapBuffers → 编码器吃 surface 出帧。
// 之前机制探针已验证：在编码器输入 surface 上创建 EGLSurface 成功（0x3000）。
// ============================================================================

bool CanvasEncoder::EnsureEgl() {
    if (eglReady_) {
        return true;
    }
    if (encoderSurface_ == nullptr) {
        LOGE("EnsureEgl: encoder surface 为空");
        return false;
    }

    eglDpy_ = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (eglDpy_ == EGL_NO_DISPLAY) {
        LOGE("eglGetDisplay 失败");
        return false;
    }
    if (!eglInitialize(eglDpy_, nullptr, nullptr)) {
        LOGE("eglInitialize 失败 0x%x", eglGetError());
        return false;
    }

    const EGLint cfgAttrs[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_NONE
    };
    EGLConfig cfg = nullptr;
    EGLint numCfg = 0;
    if (!eglChooseConfig(eglDpy_, cfgAttrs, &cfg, 1, &numCfg) || numCfg < 1) {
        LOGE("eglChooseConfig 失败 0x%x", eglGetError());
        return false;
    }

    const EGLint ctxAttrs[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
    eglCtx_ = eglCreateContext(eglDpy_, cfg, EGL_NO_CONTEXT, ctxAttrs);
    if (eglCtx_ == EGL_NO_CONTEXT) {
        LOGE("eglCreateContext 失败 0x%x", eglGetError());
        return false;
    }

    const EGLint surfAttrs[] = { EGL_NONE };
    eglSurf_ = eglCreateWindowSurface(eglDpy_, cfg,
        reinterpret_cast<EGLNativeWindowType>(encoderSurface_), surfAttrs);
    if (eglSurf_ == EGL_NO_SURFACE) {
        LOGE("eglCreateWindowSurface 失败 errno=%d", (int)eglGetError());
        return false;
    }

    if (!eglMakeCurrent(eglDpy_, eglSurf_, eglSurf_, eglCtx_)) {
        LOGE("eglMakeCurrent 失败 errno=%d", (int)eglGetError());
        return false;
    }

    // ---- GL 资源：纹理 + 着色器 ----
    glGenTextures(1, &tex_);
    glBindTexture(GL_TEXTURE_2D, tex_);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    const char *vs =
        "attribute vec2 aPos;"
        "varying vec2 vUV;"
        "void main(){ vUV = (aPos + 1.0) * 0.5; vUV.y = 1.0 - vUV.y;"
        " gl_Position = vec4(aPos, 0.0, 1.0); }";
    const char *fs =
        "precision mediump float;"
        "varying vec2 vUV;"
        "uniform sampler2D uTex;"
        "void main(){ gl_FragColor = texture2D(uTex, vUV); }";

    GLuint vsObj = glCreateShader(GL_VERTEX_SHADER);
    glShaderSource(vsObj, 1, &vs, nullptr);
    glCompileShader(vsObj);
    GLuint fsObj = glCreateShader(GL_FRAGMENT_SHADER);
    glShaderSource(fsObj, 1, &fs, nullptr);
    glCompileShader(fsObj);
    prog_ = glCreateProgram();
    glAttachShader(prog_, vsObj);
    glAttachShader(prog_, fsObj);
    glLinkProgram(prog_);
    glDeleteShader(vsObj);
    glDeleteShader(fsObj);

    eglReady_ = true;
    LOGI("EGL 就绪（编码器输入 surface）GL_VERSION=%s", glGetString(GL_VERSION));
    return true;
}

void CanvasEncoder::DestroyEgl() {
    if (!eglReady_) {
        return;
    }
    if (tex_ != 0) {
        glDeleteTextures(1, &tex_);
        tex_ = 0;
    }
    if (prog_ != 0) {
        glDeleteProgram(prog_);
        prog_ = 0;
    }
    if (eglDpy_ != EGL_NO_DISPLAY) {
        eglMakeCurrent(eglDpy_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (eglSurf_ != EGL_NO_SURFACE) {
            eglDestroySurface(eglDpy_, eglSurf_);
            eglSurf_ = EGL_NO_SURFACE;
        }
        if (eglCtx_ != EGL_NO_CONTEXT) {
            eglDestroyContext(eglDpy_, eglCtx_);
            eglCtx_ = EGL_NO_CONTEXT;
        }
        eglTerminate(eglDpy_);
        eglDpy_ = EGL_NO_DISPLAY;
    }
    eglReady_ = false;
    lastTexW_ = lastTexH_ = 0;
    LOGI("EGL 已释放");
}

void CanvasEncoder::ReleaseGlResources() {
    std::lock_guard<std::mutex> guard(lock_);
    DestroyEgl();
}

int32_t CanvasEncoder::PushPixels(int32_t w, int32_t h, const uint8_t *rgba) {
    std::lock_guard<std::mutex> guard(lock_);
    static int s_diag = 0;
    if (s_diag < 3) {
        LOGI("PushPixels#%d: started=%d surf=%d w=%d h=%d rgba=%d",
             s_diag, codecStarted_.load() ? 1 : 0,
             (encoderSurface_ != nullptr) ? 1 : 0, w, h, (rgba != nullptr) ? 1 : 0);
        s_diag++;
    }
    if (!codecStarted_.load() || encoderSurface_ == nullptr) {
        return -1;
    }
    if (rgba == nullptr || w <= 0 || h <= 0) {
        return -2;
    }
    if (!EnsureEgl()) {
        return -3;
    }

    // 上传纹理（尺寸变化时重新分配）
    glBindTexture(GL_TEXTURE_2D, tex_);
    if (w != lastTexW_ || h != lastTexH_) {
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
        lastTexW_ = w;
        lastTexH_ = h;
    } else {
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
    }

    // ★ 关键：viewport 必须等于编码器输出尺寸，且与 EGLSurface 尺寸一致。
    //   EGL_BAD_ALLOC(0x3003) 的常见成因就是「请求的 buffer 尺寸与 surface 不符」。
    int32_t vw = encodedWidth_.load();
    int32_t vh = encodedHeight_.load();
    if (vw <= 0 || vh <= 0) {
        vw = params_.width;
        vh = params_.height;
    }
    static int s_geom = 0;
    if (s_geom < 3) {
        LOGI("PushPixels 几何: 纹理=%dx%d 编码器=%dx%d", w, h, vw, vh);
        s_geom++;
    }
    // 让 GL 知道 surface 的真实尺寸（避免 EGL 按默认尺寸分配 buffer）
    glViewport(0, 0, vw, vh);
    glUseProgram(prog_);
    static const float quad[8] = {
        -1.0f, -1.0f,  1.0f, -1.0f,  -1.0f, 1.0f,  1.0f, 1.0f
    };
    GLint aPos = glGetAttribLocation(prog_, "aPos");
    glEnableVertexAttribArray(aPos);
    glVertexAttribPointer(aPos, 2, GL_FLOAT, GL_FALSE, 0, quad);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

    if (!eglSwapBuffers(eglDpy_, eglSurf_)) {
        // ★ 错误码走返回值：hilog 对数字会脱敏成 <private>，日志读不到。
        //   编码规则：-1000 - eglGetError()，调用方减回去即可。
        //   常见 EGL 错误码：12288(0x3000) SUCCESS / 12289(0x3001) NOT_INITIALIZED
        //   / 12290(0x3002) BAD_ACCESS / 12291(0x3003) BAD_ALLOC
        //   / 12292(0x3004) BAD_ATTRIBUTE / 12293(0x3005) BAD_CONFIG
        //   / 12294(0x3006) BAD_CONTEXT / 12295(0x3007) BAD_CURRENT_SURFACE
        //   / 12296(0x3008) BAD_DISPLAY / 12297(0x3009) BAD_MATCH
        //   / 12298(0x300A) BAD_NATIVE_PIXMAP / 12299(0x300B) BAD_NATIVE_WINDOW
        //   / 12300(0x300C) BAD_PARAMETER / 12301(0x300D) CONTEXT_LOST
        return -1000 - static_cast<int32_t>(eglGetError());
    }
    return 0;
}

void CanvasEncoder::ReleaseCodec() {
    if (codec_ != nullptr) {
        if (codecStarted_.load()) {
            OH_VideoEncoder_Stop(codec_);
            codecStarted_.store(false);
        }
        OH_VideoEncoder_Destroy(codec_);
        codec_ = nullptr;
    }
    if (encoderSurface_ != nullptr) {
        OH_NativeWindow_NativeObjectUnreference(encoderSurface_);
        encoderSurface_ = nullptr;
    }
    if (canvasSurface_ != nullptr) {
        OH_NativeWindow_NativeObjectUnreference(canvasSurface_);
        canvasSurface_ = nullptr;
    }
    running_.store(false);
}

void CanvasEncoder::RequestKeyFrame() {
    forceKeyFrame_.store(true);
    // 低延迟模式下用 SetParameter 请求 I 帧（不重建管线）
    std::lock_guard<std::mutex> guard(lock_);
    if (codec_ != nullptr && codecStarted_.load()) {
        OH_AVFormat *fmt = OH_AVFormat_Create();
        if (fmt != nullptr) {
            OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_REQUEST_I_FRAME, 1);
            OH_VideoEncoder_SetParameter(codec_, fmt);
            OH_AVFormat_Destroy(fmt);
        }
    }
}

int32_t CanvasEncoder::SetFrameRate(int32_t frameRate) {
    if (frameRate <= 0) {
        return -1;
    }
    std::lock_guard<std::mutex> guard(lock_);
    if (codec_ == nullptr || !codecStarted_.load()) {
        return -1;
    }
    OH_AVFormat *fmt = OH_AVFormat_Create();
    if (fmt == nullptr) {
        return -1;
    }
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_FRAME_RATE, frameRate);
    OH_AVErrCode err = OH_VideoEncoder_SetParameter(codec_, fmt);
    OH_AVFormat_Destroy(fmt);
    if (err == AV_ERR_OK) {
        params_.frameRate = frameRate;
        LOGI("encoder frame rate changed to %{public}d", frameRate);
        return 0;
    }
    return -1;
}

int32_t CanvasEncoder::PushFrame(const uint8_t *data, int32_t size, int64_t pts) {
    // 保留给"不用 Surface 而用 buffer 喂帧"的场景（如将来自己做 CPU 合成）。
    // 当前 A2 路线走 Surface，不需要这条。占位实现，避免链接期缺失。
    (void)data;
    (void)size;
    (void)pts;
    return -1;
}

// ---------------------------------------------------------------------------
// 编码器回调
// ---------------------------------------------------------------------------

void CanvasEncoder::OnCodecError(OH_AVCodec * /*codec*/, int32_t errorCode, void *userData) {
    auto *self = static_cast<CanvasEncoder *>(userData);
    if (self == nullptr) {
        return;
    }

    // ★ 真机实测踩坑（2026-10-15，MRT-AL10 / HarmonyOS 7.0.0.109）：
    //   编码器**正常出帧**的同时会回调一次 onError(errorCode == 0)。
    //   0 是 AV_ERR_OK（成功），根本不是错误 —— 但上报到 ArkTS 后，
    //   上层无条件当成故障处理 → stopStreaming() → 管线自杀 →
    //   表现为「启动 372ms 后画面通路自己停了，车机黑屏」。
    //
    //   日志铁证：同一时刻 `encoder output #2: size=29704 flags=2`（一个完整 I 帧），
    //   紧接着 `[画面] 错误(...): 0` → `[自绘] 画面通路已停止`。
    //
    //   所以这里**必须把 0 过滤掉**：它是伪错误，转成一条 INFO 就够，
    //   绝不能让它冒泡到错误回调（那会拆掉整条推流管线）。
    if (errorCode == 0) {
        LOGI("编码器 onError 回调 errorCode=0（AV_ERR_OK，伪错误，忽略）");
        return;
    }

    self->EmitError(errorCode, "video encoder error");
}

void CanvasEncoder::OnStreamChanged(OH_AVCodec * /*codec*/, OH_AVFormat *format, void *userData) {
    auto *self = static_cast<CanvasEncoder *>(userData);
    if (self == nullptr || format == nullptr) {
        return;
    }
    int32_t w = 0;
    int32_t h = 0;
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_WIDTH, &w);
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_HEIGHT, &h);
    self->encodedWidth_.store(w);
    self->encodedHeight_.store(h);
    LOGI("encoder stream changed: %{public}dx%{public}d", w, h);
}

void CanvasEncoder::OnNeedInputBuffer(OH_AVCodec * /*codec*/, uint32_t /*index*/,
                                      OH_AVBuffer * /*buffer*/, void * /*userData*/) {
    // Surface 输入模式：编码器自己从 Surface 取帧，不需要我们喂输入缓冲。
    // 这个回调在 Surface 模式下不会被触发（保留空实现以防某些实现会调用）。
}

void CanvasEncoder::OnNewOutputBuffer(OH_AVCodec * /*codec*/, uint32_t index,
                                      OH_AVBuffer *buffer, void *userData) {
    auto *self = static_cast<CanvasEncoder *>(userData);
    if (self != nullptr) {
        self->HandleNewOutputBuffer(index, buffer);
    }
}

void CanvasEncoder::HandleNewOutputBuffer(uint32_t index, OH_AVBuffer *buffer) {
    if (buffer == nullptr || onFrame_ == nullptr) {
        return;
    }
    OH_AVCodecBufferAttr attr{};
    if (OH_AVBuffer_GetBufferAttr(buffer, &attr) != AV_ERR_OK) {
        return;
    }

    if (outputFrameCount_ < 3) {
        LOGI("encoder output #%{public}d: size=%{public}d flags=%{public}u pts=%{public}lld",
             outputFrameCount_ + 1, attr.size, attr.flags, static_cast<long long>(attr.pts));
    }
    outputFrameCount_++;

    uint8_t *addr = OH_AVBuffer_GetAddr(buffer);
    if (addr != nullptr && attr.size > 0) {
        EncodedFrame frame{};
        frame.data = addr;
        frame.size = attr.size;
        frame.pts = attr.pts;
        frame.keyFrame = (attr.flags & AVCODEC_BUFFER_FLAGS_SYNC_FRAME) != 0;
        onFrame_(frame);
    }

    // 归还 buffer 给编码器继续用
    OH_VideoEncoder_FreeOutputBuffer(codec_, index);
}

void CanvasEncoder::EmitError(int32_t code, const std::string &msg) {
    LOGE("encoder error code=%{public}d msg=%{public}s", code, msg.c_str());
    if (onError_) {
        onError_(code, msg);
    }
}

} // namespace carhi
