#include "screen_encoder.h"

#include <cstring>

#include <hilog/log.h>
#include <native_window/external_window.h>
#include <multimedia/player_framework/native_averrors.h>

#define LOG_DOMAIN 0x0001
#define LOG_TAG "CarHiNative"
#define LOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
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
    // 这几个状态是"用户/系统把采集掐了"，必须让上层知道，否则会一直推空流
    switch (stateCode) {
        case OH_SCREEN_CAPTURE_STATE_STARTED:
            LOGI("screen capture started");
            break;
        case OH_SCREEN_CAPTURE_STATE_CANCELED:
            self->EmitError(-1, "screen capture canceled by user");
            break;
        case OH_SCREEN_CAPTURE_STATE_STOPPED_BY_USER:
            self->EmitError(-2, "screen capture stopped by user");
            break;
        case OH_SCREEN_CAPTURE_STATE_STOPPED_BY_CALL:
            self->EmitError(-3, "screen capture stopped by incoming call");
            break;
        case OH_SCREEN_CAPTURE_STATE_INTERRUPTED_BY_OTHER:
            self->EmitError(-4, "screen capture interrupted by other app");
            break;
        default:
            LOGI("screen capture state=%{public}d", static_cast<int32_t>(stateCode));
            break;
    }
}

void ScreenEncoder::OnCaptureError(OH_AVScreenCapture *capture, int32_t errorCode, void *userData) {
    (void)capture;
    auto *self = static_cast<ScreenEncoder *>(userData);
    if (self != nullptr) {
        self->EmitError(errorCode, "screen capture error");
    }
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
    capture_ = OH_AVScreenCapture_Create();
    if (capture_ == nullptr) {
        ReleaseCodec();
        return STAGE_CREATE_CAPTURE_FAILED;
    }

    OH_AVScreenCaptureConfig config{};
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
        ReleaseCodec();
        return STAGE_INIT_CAPTURE_FAILED;
    }

    OH_AVScreenCapture_SetStateCallback(capture_, &ScreenEncoder::OnCaptureState, this);
    OH_AVScreenCapture_SetErrorCallback(capture_, &ScreenEncoder::OnCaptureError, this);
    OH_AVScreenCapture_SetMaxVideoFrameRate(capture_, params_.frameRate);

    // 采集输出直连编码器输入 Surface —— 零拷贝的关键一步
    scErr = OH_AVScreenCapture_StartScreenCaptureWithSurface(capture_, encoderSurface_);
    if (scErr != AV_SCREEN_CAPTURE_ERR_OK) {
        ReleaseCapture();
        ReleaseCodec();
        return STAGE_START_CAPTURE_FAILED;
    }
    captureStarted_.store(true);
    running_.store(true);

    LOGI("pipeline up: %{public}dx%{public}d@%{public}d bitrate=%{public}d",
         params_.width, params_.height, params_.frameRate, params_.bitrate);
    if (onLog_) {
        onLog_("采集与编码管线已启动");
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

} // namespace carhi
