#include "screen_encoder.h"

#include <chrono>
#include <cstring>

#include <hilog/log.h>
#include <native_window/external_window.h>
#include <multimedia/player_framework/native_averrors.h>

#define LOG_DOMAIN 0x0001
#define LOG_TAG "CarHiNative"
#define LOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define LOGW(...) OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)

namespace carhi {

namespace {

/** 启动失败阶段，便于定位（返回值即阶段号） */
enum StartStage {
    STAGE_OK = 0,
    STAGE_CREATE_CODEC_FAILED = 1,
    STAGE_CONFIGURE_FAILED = 2,
    STAGE_GET_SURFACE_FAILED = 3,
    STAGE_REGISTER_CALLBACK_FAILED = 4,
    STAGE_PREPARE_FAILED = 5,
    STAGE_START_CODEC_FAILED = 6,
    STAGE_CREATE_CAPTURE_FAILED = 7,
    STAGE_INIT_CAPTURE_FAILED = 8,
    STAGE_START_CAPTURE_FAILED = 9,
};

/**
 * 采集重启冷却时间（毫秒）。
 * 重建采集会换掉编码器 Surface，车机侧必须等到下一个 I 帧才能恢复，
 * 所以低于这个间隔的重复重启请求一律忽略（见 RestartCapture）。
 */
constexpr int64_t kRestartCooldownMs = 3000;

/** 把失败阶段翻成人话，直接进日志与 UI */
const char *StageName(int32_t stage) {
    switch (stage) {
        case STAGE_CREATE_CODEC_FAILED: return "OH_VideoEncoder_CreateByMime failed";
        case STAGE_CONFIGURE_FAILED: return "OH_VideoEncoder_Configure failed";
        case STAGE_GET_SURFACE_FAILED: return "OH_VideoEncoder_GetSurface failed";
        case STAGE_REGISTER_CALLBACK_FAILED: return "OH_VideoEncoder_RegisterCallback failed";
        case STAGE_PREPARE_FAILED: return "OH_VideoEncoder_Prepare failed";
        case STAGE_START_CODEC_FAILED: return "OH_VideoEncoder_Start failed";
        case STAGE_CREATE_CAPTURE_FAILED: return "OH_AVScreenCapture_Create failed";
        case STAGE_INIT_CAPTURE_FAILED: return "OH_AVScreenCapture_Init failed";
        case STAGE_START_CAPTURE_FAILED: return "OH_AVScreenCapture_StartScreenCaptureWithSurface failed";
        default: return "unknown stage";
    }
}

} // namespace

ScreenEncoder::~ScreenEncoder() {
    Stop();
}

// ---------------------------------------------------------------------------
// 编码器回调
// ---------------------------------------------------------------------------

void ScreenEncoder::OnCodecError(OH_AVCodec *codec, int32_t errorCode, void *userData) {
    (void)codec;
    auto *self = static_cast<ScreenEncoder *>(userData);
    if (self != nullptr) {
        self->EmitError(errorCode, "video encoder error");
    }
}

void ScreenEncoder::OnStreamChanged(OH_AVCodec *codec, OH_AVFormat *format, void *userData) {
    (void)codec;
    auto *self = static_cast<ScreenEncoder *>(userData);
    if (self == nullptr || format == nullptr) {
        return;
    }
    // 编码器可能按硬件对齐调整实际输出尺寸，记录下来供上层核对
    int32_t w = 0;
    int32_t h = 0;
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_WIDTH, &w);
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_HEIGHT, &h);
    if (w > 0 && h > 0) {
        self->encodedWidth_.store(w);
        self->encodedHeight_.store(h);
        LOGI("encoder stream changed: %{public}dx%{public}d", w, h);
    }
}

void ScreenEncoder::OnNeedInputBuffer(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData) {
    // Surface 模式：输入缓冲由编码器输入 Surface 填充，应用侧**不应**调用
    // OH_VideoEncoder_PushInputBuffer（官方头文件注明该接口仅用于 buffer 模式）。
    // 因此这里刻意留空。
    (void)codec;
    (void)index;
    (void)buffer;
    (void)userData;
}

void ScreenEncoder::OnNewOutputBuffer(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData) {
    (void)codec;
    auto *self = static_cast<ScreenEncoder *>(userData);
    if (self == nullptr) {
        return;
    }
    self->HandleNewOutputBuffer(index, buffer);
}

void ScreenEncoder::HandleNewOutputBuffer(uint32_t index, OH_AVBuffer *buffer) {
    if (buffer == nullptr || codec_ == nullptr) {
        return;
    }

    OH_AVCodecBufferAttr attr{};
    if (OH_AVBuffer_GetBufferAttr(buffer, &attr) != AV_ERR_OK) {
        OH_VideoEncoder_FreeOutputBuffer(codec_, index);
        return;
    }

    const uint8_t *addr = OH_AVBuffer_GetAddr(buffer);
    // CODEC_DATA 是 SPS/PPS 之类的配置帧，同样属于裸流的一部分，需要一起发出去，
    // 否则车机侧解不出画面（ffmpeg 能容忍，但硬解通常不能）。
    const bool keyFrame = (attr.flags & AVCODEC_BUFFER_FLAGS_SYNC_FRAME) != 0;
    const bool codecData = (attr.flags & AVCODEC_BUFFER_FLAGS_CODEC_DATA) != 0;
    const bool eos = (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0;

    if (addr != nullptr && attr.size > 0 && !eos && onFrame_) {
        EncodedFrame frame{};
        frame.data = addr + attr.offset;
        frame.size = attr.size;
        frame.pts = attr.pts;
        frame.keyFrame = keyFrame || codecData;
        onFrame_(frame);
    }

    OH_VideoEncoder_FreeOutputBuffer(codec_, index);
}

// ---------------------------------------------------------------------------
// 采集回调
// ---------------------------------------------------------------------------

void ScreenEncoder::OnCaptureState(OH_AVScreenCapture *capture, OH_AVScreenCaptureStateCode stateCode, void *userData) {
    (void)capture;
    auto *self = static_cast<ScreenEncoder *>(userData);
    if (self == nullptr) {
        return;
    }
    switch (stateCode) {
        // ---- 正常事件，绝不触发重启 ----
        case OH_SCREEN_CAPTURE_STATE_STARTED:
            LOGI("screen capture started");
            break;

        // 本方案音频走蓝牙 A2DP，根本不用麦克风。系统报麦克风不可用/被静音
        // 属于正常现象（例如无麦克风权限、被其他应用占用）。
        // ⚠️ 历史教训：这几个状态曾被当成"采集中断"去重启管线，结果每 2 秒就把
        // 好好的采集拆掉重建，车机侧表现为持续掉线。必须忽略。
        case OH_SCREEN_CAPTURE_STATE_MIC_UNAVAILABLE:
            LOGI("mic unavailable (ignored, audio via A2DP)");
            break;
        case OH_SCREEN_CAPTURE_STATE_MIC_MUTED_BY_USER:
            LOGI("mic muted (ignored, audio via A2DP)");
            break;
        case OH_SCREEN_CAPTURE_STATE_MIC_UNMUTED_BY_USER:
            LOGI("mic unmuted (ignored, audio via A2DP)");
            break;

        // 隐私窗口进入/退出：画面内容变化，采集管线本身没断，继续推即可。
        case OH_SCREEN_CAPTURE_STATE_ENTER_PRIVATE_SCENE:
            LOGI("private scene entered (content masked, capture continues)");
            break;
        case OH_SCREEN_CAPTURE_STATE_EXIT_PRIVATE_SCENE:
            LOGI("private scene exited");
            break;

        // 26.0.0 新增的应用侧暂停/恢复：我们从不主动暂停，记录即可。
        case OH_SCREEN_CAPTURE_STATE_PAUSED_BY_USER:
        case OH_SCREEN_CAPTURE_STATE_RESUMED_BY_USER:
        case OH_SCREEN_CAPTURE_STATE_PAUSED_BY_APP:
        case OH_SCREEN_CAPTURE_STATE_RESUMED_BY_APP:
            LOGI("screen capture pause/resume state=%{public}d", static_cast<int32_t>(stateCode));
            break;

        // ---- 采集真的被终止，需要上层介入 ----
        // 注意：系统也可能用 STOPPED_BY_USER_SWITCHES 表达"捕获源切换"，
        // 但那属于正常生命周期事件，不做恢复，仅记录。
        case OH_SCREEN_CAPTURE_STATE_STOPPED_BY_USER_SWITCHES:
            LOGI("screen capture stopped by user switches (source changed)");
            break;
        case OH_SCREEN_CAPTURE_STATE_CANCELED:
            self->EmitError(INTERRUPT_CANCELED_BY_USER, "screen capture canceled by user");
            break;
        case OH_SCREEN_CAPTURE_STATE_STOPPED_BY_USER:
            self->EmitError(INTERRUPT_STOPPED_BY_USER, "screen capture stopped by user");
            break;
        case OH_SCREEN_CAPTURE_STATE_STOPPED_BY_CALL:
            self->EmitError(INTERRUPT_STOPPED_BY_CALL, "screen capture stopped by incoming call");
            break;
        case OH_SCREEN_CAPTURE_STATE_INTERRUPTED_BY_OTHER:
            self->EmitError(INTERRUPT_BY_OTHER, "screen capture interrupted by other app");
            break;
        default:
            LOGI("screen capture state=%{public}d (unhandled)", static_cast<int32_t>(stateCode));
            break;
    }
}

void ScreenEncoder::OnCaptureError(OH_AVScreenCapture *capture, int32_t errorCode, void *userData) {
    (void)capture;
    auto *self = static_cast<ScreenEncoder *>(userData);
    if (self != nullptr) {
        // 底层报错多为临时性问题（surface 重建、系统资源紧张），标记为可恢复
        self->EmitError(INTERRUPT_CAPTURE_ERROR, "screen capture error");
    }
    LOGE("capture error callback code=%{public}d", errorCode);
}

bool ScreenEncoder::IsRecoverable(int32_t code) {
    // 只有"用户在系统弹窗点取消/主动停止"才是致命；其余都值得重试
    return code != INTERRUPT_CANCELED_BY_USER && code != INTERRUPT_STOPPED_BY_USER;
}

void ScreenEncoder::EmitError(int32_t code, const std::string &msg) {
    LOGE("%{public}s code=%{public}d", msg.c_str(), code);
    if (onError_) {
        onError_(code, msg);
    }
}

// ---------------------------------------------------------------------------
// 启动
// ---------------------------------------------------------------------------

int32_t ScreenEncoder::Start(const EncoderParams &params, FrameCallback onFrame,
                             ErrorCallback onError, LogCallback onLog) {
    if (running_.load()) {
        LOGI("already running, ignore Start");
        return STAGE_OK;
    }

    params_ = params;
    onFrame_ = std::move(onFrame);
    onError_ = std::move(onError);
    onLog_ = std::move(onLog);
    forceKeyFrame_.store(false);

    // ---------------- 1. 编码器 ----------------
    codec_ = OH_VideoEncoder_CreateByMime(OH_AVCODEC_MIMETYPE_VIDEO_AVC);
    if (codec_ == nullptr) {
        return STAGE_CREATE_CODEC_FAILED;
    }

    OH_AVFormat *format = OH_AVFormat_Create();
    if (format == nullptr) {
        ReleaseCodec();
        return STAGE_CONFIGURE_FAILED;
    }

    OH_AVFormat_SetStringValue(format, OH_MD_KEY_CODEC_MIME, OH_AVCODEC_MIMETYPE_VIDEO_AVC);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_WIDTH, params_.width);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_HEIGHT, params_.height);
    // 输入走 Surface：采集画面直接送进来，不经过 CPU 拷贝
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_SURFACE_FORMAT);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_FRAME_RATE, params_.frameRate);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_BITRATE, params_.bitrate);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_MAX_BITRATE, params_.bitrate);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_VIDEO_ENCODE_BITRATE_MODE, BITRATE_MODE_CBR);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_I_FRAME_INTERVAL, params_.iFrameIntervalMs);
    // Baseline：无 B 帧、无 CABAC —— 安卓 4.4 老车机硬解最稳的组合
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

    OH_AVCodecCallback callbacks{};
    callbacks.onError = &ScreenEncoder::OnCodecError;
    callbacks.onStreamChanged = &ScreenEncoder::OnStreamChanged;
    callbacks.onNeedInputBuffer = &ScreenEncoder::OnNeedInputBuffer;
    callbacks.onNewOutputBuffer = &ScreenEncoder::OnNewOutputBuffer;
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

    // ---------------- 2. 屏幕采集 ----------------
    int32_t captureStage = StartCaptureLocked();
    if (captureStage != STAGE_OK) {
        ReleaseCodec();
        return captureStage;
    }

    running_.store(true);

    LOGI("pipeline up: %{public}dx%{public}d@%{public}d bitrate=%{public}d",
         params_.width, params_.height, params_.frameRate, params_.bitrate);
    if (onLog_) {
        onLog_("采集与编码管线已启动");
    }
    return STAGE_OK;
}

// ---------------------------------------------------------------------------
// 采集侧：独立成函数，便于"只重建采集、不动编码器"的快速恢复
// ---------------------------------------------------------------------------

int32_t ScreenEncoder::StartCaptureLocked() {
    capture_ = OH_AVScreenCapture_Create();
    if (capture_ == nullptr) {
        return STAGE_CREATE_CAPTURE_FAILED;
    }

    OH_AVScreenCaptureConfig config{};
    // 整屏采集：本方案推的就是整个手机画面（用户在手机上开系统驾驶模式，
    // 本应用在后台把整块屏推给车机），因此固定 HOME_SCREEN，不做窗口级采集。
    config.captureMode = OH_CAPTURE_HOME_SCREEN;
    config.dataType = OH_ORIGINAL_STREAM;   // 原始流：交给编码器，不落文件

    // 本方案音频走蓝牙 A2DP 独立通道，采集侧不需要音频；
    // 但结构体字段需填合法值，否则 Init 会参数校验失败。
    config.audioInfo.micCapInfo.audioSampleRate = 48000;
    config.audioInfo.micCapInfo.audioChannels = 2;
    config.audioInfo.micCapInfo.audioSource = OH_SOURCE_DEFAULT;
    config.audioInfo.innerCapInfo.audioSampleRate = 48000;
    config.audioInfo.innerCapInfo.audioChannels = 2;
    config.audioInfo.innerCapInfo.audioSource = OH_ALL_PLAYBACK;
    config.audioInfo.audioEncInfo.audioBitrate = 0;
    config.audioInfo.audioEncInfo.audioCodecformat = OH_AUDIO_DEFAULT;

    config.videoInfo.videoCapInfo.missionIDs = nullptr;
    config.videoInfo.videoCapInfo.missionIDsLen = 0;
    config.videoInfo.videoCapInfo.videoFrameWidth = params_.width;
    config.videoInfo.videoCapInfo.videoFrameHeight = params_.height;
    config.videoInfo.videoCapInfo.videoSource = OH_VIDEO_SOURCE_SURFACE_RGBA;
    config.videoInfo.videoEncInfo.videoCodec = OH_H264;
    config.videoInfo.videoEncInfo.videoBitrate = params_.bitrate;
    config.videoInfo.videoEncInfo.videoFrameRate = params_.frameRate;

    config.recorderInfo.fileFormat = CFT_MPEG_4;   // 原始流模式下不生效，填合法值即可

    // 屏幕采集的错误码类型与编码器不同（OH_AVSCREEN_CAPTURE_ErrCode vs OH_AVErrCode），
    // 成功常量也不同（AV_SCREEN_CAPTURE_ERR_OK vs AV_ERR_OK），必须分开声明。
    OH_AVSCREEN_CAPTURE_ErrCode scErr = OH_AVScreenCapture_Init(capture_, config);
    if (scErr != AV_SCREEN_CAPTURE_ERR_OK) {
        ReleaseCapture();
        return STAGE_INIT_CAPTURE_FAILED;
    }

    OH_AVScreenCapture_SetStateCallback(capture_, &ScreenEncoder::OnCaptureState, this);
    OH_AVScreenCapture_SetErrorCallback(capture_, &ScreenEncoder::OnCaptureError, this);
    OH_AVScreenCapture_SetMaxVideoFrameRate(capture_, params_.frameRate);

    // ★ 采集策略：必须在 StartScreenCapture* 之前设置，否则返回 INVALID_STATE。
    // 关键作用是关掉"启动后统一弹 Picker（授权框）"——CarLife 场景下手机固定作为
    // 常驻推流端，每次重启采集都弹框会直接把投屏画面打断，且无法在息屏/无人值守下工作。
    // 参考：native_avscreen_capture.h 中 OH_AVScreenCapture_StrategyForPickerPopUp
    //       "If set to false, it means that the APP don't need to pop up the Picker
    //        after screen capture starts" （@since 20）
    ApplyCaptureStrategyLocked();

    // 采集输出直连编码器输入 Surface —— 零拷贝的关键一步
    scErr = OH_AVScreenCapture_StartScreenCaptureWithSurface(capture_, encoderSurface_);
    if (scErr != AV_SCREEN_CAPTURE_ERR_OK) {
        ReleaseCapture();
        return STAGE_START_CAPTURE_FAILED;
    }
    captureStarted_.store(true);
    LOGI("screen capture started with surface");
    return STAGE_OK;
}

// ---------------------------------------------------------------------------
// 采集策略：关闭"启动后统一弹 Picker"，让采集在无人工确认的前提下长期存活
// ---------------------------------------------------------------------------
void ScreenEncoder::ApplyCaptureStrategyLocked() {
    if (capture_ == nullptr) {
        return;
    }

    OH_AVScreenCapture_CaptureStrategy *strategy = OH_AVScreenCapture_CreateCaptureStrategy();
    if (strategy == nullptr) {
        // 设备/版本不支持策略接口（@since 20）：退化为系统默认行为，只是会弹框。
        LOGW("CreateCaptureStrategy failed, fallback to default picker behavior");
        return;
    }

    // ① 不弹 Picker —— 本方案的核心诉求。
    //    注意语义：false = "启动后不需要弹 Picker"，即由应用自行承担授权合法性；
    //    true = 统一在启动后弹；不设置 = 走系统推荐行为（当前系统会弹）。
    OH_AVSCREEN_CAPTURE_ErrCode err =
        OH_AVScreenCapture_StrategyForPickerPopUp(strategy, false);
    if (err != AV_SCREEN_CAPTURE_ERR_OK) {
        LOGW("StrategyForPickerPopUp(false) failed: %{public}d", static_cast<int32_t>(err));
    }

    // ② 通话中继续采集（默认 false）。CarLife 场景下手机常伴随车机蓝牙通话，
    //    若中途被掐断会直接表现成"投屏掉线"，因此显式打开。
    err = OH_AVScreenCapture_StrategyForKeepCaptureDuringCall(strategy, true);
    if (err != AV_SCREEN_CAPTURE_ERR_OK) {
        LOGW("StrategyForKeepCaptureDuringCall(true) failed: %{public}d", static_cast<int32_t>(err));
    }

    // ③ 旋转跟随：车机横屏、手机可能竖屏启动。开启后虚拟屏尺寸随系统旋转自动调整，
    //    不必再手动调 ResizeCanvas，避免出现画面拉伸/黑边。
    err = OH_AVScreenCapture_StrategyForCanvasFollowRotation(strategy, true);
    if (err != AV_SCREEN_CAPTURE_ERR_OK) {
        LOGW("StrategyForCanvasFollowRotation(true) failed: %{public}d", static_cast<int32_t>(err));
    }

    err = OH_AVScreenCapture_SetCaptureStrategy(capture_, strategy);
    if (err != AV_SCREEN_CAPTURE_ERR_OK) {
        LOGE("SetCaptureStrategy failed: %{public}d", static_cast<int32_t>(err));
    } else {
        LOGI("capture strategy applied: pickerPopUp=false, keepDuringCall=true, followRotation=true");
    }

    // 策略对象被 Set 之后由 capture 内部持有/拷贝，此处即可释放。
    OH_AVScreenCapture_ReleaseCaptureStrategy(strategy);
}

int32_t ScreenEncoder::RestartCapture() {
    std::lock_guard<std::mutex> guard(lock_);
    if (codec_ == nullptr || encoderSurface_ == nullptr) {
        // 编码器已经不在了，单靠重启采集救不回来
        return STAGE_START_CAPTURE_FAILED;
    }

    // 防抖：重建采集会强制换掉编码器 Surface，车机侧要等下一个 I 帧才能恢复画面，
    // 因此短时间内重复重启只会让画面反复花屏/卡顿。
    // 这里做一次冷却，冷却期内直接返回成功（假装已恢复），让上层不必再重试。
    const int64_t nowMs = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
    if (lastRestartMs_ != 0 && nowMs - lastRestartMs_ < kRestartCooldownMs) {
        LOGI("restart requested within cooldown (%{public}lld ms), skipped",
             static_cast<long long>(nowMs - lastRestartMs_));
        return STAGE_OK;
    }

    LOGI("restarting screen capture (codec kept alive)");
    if (onLog_) {
        onLog_("正在重新建立屏幕采集...");
    }
    ReleaseCapture();
    int32_t stage = StartCaptureLocked();
    if (stage != STAGE_OK) {
        LOGE("restart capture failed at stage %{public}d", stage);
        running_.store(false);
        return stage;
    }
    lastRestartMs_ = nowMs;
    // 恢复后立刻补一个 I 帧，让车机侧不用等 GOP
    forceKeyFrame_.store(true);
    running_.store(true);
    if (onLog_) {
        onLog_("屏幕采集已恢复");
    }
    return STAGE_OK;
}

// ---------------------------------------------------------------------------
// 停止
// ---------------------------------------------------------------------------

void ScreenEncoder::ReleaseCapture() {
    if (capture_ != nullptr) {
        if (captureStarted_.load()) {
            OH_AVScreenCapture_StopScreenCapture(capture_);
            captureStarted_.store(false);
        }
        OH_AVScreenCapture_Release(capture_);
        capture_ = nullptr;
    }
}

void ScreenEncoder::ReleaseCodec() {
    if (codec_ != nullptr) {
        if (codecStarted_.load()) {
            OH_VideoEncoder_Stop(codec_);
            codecStarted_.store(false);
        }
        OH_VideoEncoder_Destroy(codec_);
        codec_ = nullptr;
    }
    // 官方要求应用自己管理这个窗口的生命周期
    if (encoderSurface_ != nullptr) {
        OH_NativeWindow_DestroyNativeWindow(encoderSurface_);
        encoderSurface_ = nullptr;
    }
}

void ScreenEncoder::Stop() {
    std::lock_guard<std::mutex> guard(lock_);
    if (!running_.load() && codec_ == nullptr && capture_ == nullptr) {
        return;
    }
    running_.store(false);
    // 先停采集再停编码：反过来的话采集仍在往一个已销毁的 Surface 写数据
    ReleaseCapture();
    ReleaseCodec();
    onFrame_ = nullptr;
    LOGI("pipeline stopped");
}

void ScreenEncoder::RequestKeyFrame() {
    if (codec_ == nullptr || !codecStarted_.load()) {
        return;
    }
    OH_AVFormat *format = OH_AVFormat_Create();
    if (format == nullptr) {
        return;
    }
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_REQUEST_I_FRAME, 1);
    OH_VideoEncoder_SetParameter(codec_, format);
    OH_AVFormat_Destroy(format);
}

int32_t ScreenEncoder::SetFrameRate(int32_t frameRate) {
    if (frameRate <= 0) {
        return -1;
    }
    std::lock_guard<std::mutex> guard(lock_);
    if (codec_ == nullptr || !codecStarted_.load()) {
        return -1;
    }
    if (frameRate == params_.frameRate) {
        return 0;   // 无变化，避免无谓的 SetParameter
    }

    OH_AVFormat *format = OH_AVFormat_Create();
    if (format == nullptr) {
        return -1;
    }
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_FRAME_RATE, frameRate);
    OH_AVErrCode err = OH_VideoEncoder_SetParameter(codec_, format);
    OH_AVFormat_Destroy(format);

    if (err != AV_ERR_OK) {
        LOGE("SetFrameRate(%{public}d) failed: %{public}d", frameRate, static_cast<int32_t>(err));
        return -1;
    }

    // 同步更新采集侧上限，否则采集仍会按旧帧率出帧。
    if (capture_ != nullptr) {
        OH_AVScreenCapture_SetMaxVideoFrameRate(capture_, frameRate);
    }
    params_.frameRate = frameRate;
    LOGI("frame rate changed to %{public}d (pipeline kept alive)", frameRate);
    return 0;
}

} // namespace carhi
