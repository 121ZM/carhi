#include "keepalive_capture.h"

#include <algorithm>
#include <limits>
#include <utility>

#include <hilog/log.h>
#include <multimedia/player_framework/native_avbuffer.h>

#define LOG_DOMAIN 0x0001
#define LOG_TAG "CarHiNative"
#define LOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define LOGW(...) OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)

namespace carhi {

KeepAliveCapture::~KeepAliveCapture() {
    Stop();
}

int32_t KeepAliveCapture::Start(bool micEnabled, AudioCallback onAudioFrame) {
    std::lock_guard<std::mutex> guard(lock_);
    if (running_.load()) {
        LOGI("audio capture already running");
        return KA_STAGE_ALREADY_RUNNING;
    }

    {
        std::lock_guard<std::mutex> callbackGuard(callbackLock_);
        onAudioFrame_ = std::move(onAudioFrame);
    }
    micEnabled_.store(micEnabled);
    interrupted_.store(0);
    lastStage_.store(KA_STAGE_OK);

    capture_ = OH_AVScreenCapture_Create();
    if (capture_ == nullptr) {
        lastStage_.store(KA_STAGE_CREATE_FAILED);
        std::lock_guard<std::mutex> callbackGuard(callbackLock_);
        onAudioFrame_ = nullptr;
        return KA_STAGE_CREATE_FAILED;
    }

    // 原始流模式：只采系统播放音频，视频宽高为 0（官方定义为不采屏幕）。
    // AudioEncInfo 在 OH_ORIGINAL_STREAM 下无需设置，音频 buffer 直接回调给上层。
    OH_AVScreenCaptureConfig config{};
    config.captureMode = OH_CAPTURE_HOME_SCREEN;
    config.dataType = OH_ORIGINAL_STREAM;

    config.audioInfo.innerCapInfo.audioSampleRate = 48000;
    config.audioInfo.innerCapInfo.audioChannels = 2;
    config.audioInfo.innerCapInfo.audioSource = OH_ALL_PLAYBACK;

    if (micEnabled) {
        config.audioInfo.micCapInfo.audioSampleRate = 48000;
        config.audioInfo.micCapInfo.audioChannels = 2;
        config.audioInfo.micCapInfo.audioSource = OH_SOURCE_DEFAULT;
    }

    config.videoInfo.videoCapInfo.videoFrameWidth = 0;
    config.videoInfo.videoCapInfo.videoFrameHeight = 0;

    const OH_AVSCREEN_CAPTURE_ErrCode initErr = OH_AVScreenCapture_Init(capture_, config);
    if (initErr != AV_SCREEN_CAPTURE_ERR_OK) {
        LOGE("audio-only OH_AVScreenCapture_Init failed code=%{public}d", static_cast<int32_t>(initErr));
        lastStage_.store(KA_STAGE_INIT_FAILED);
        ReleaseLocked();
        return KA_STAGE_INIT_FAILED;
    }

    OH_AVSCREEN_CAPTURE_ErrCode err =
        OH_AVScreenCapture_SetStateCallback(capture_, &KeepAliveCapture::OnState, this);
    if (err != AV_SCREEN_CAPTURE_ERR_OK) {
        LOGW("SetStateCallback failed code=%{public}d", static_cast<int32_t>(err));
    }

    err = OH_AVScreenCapture_SetErrorCallback(capture_, &KeepAliveCapture::OnError, this);
    if (err != AV_SCREEN_CAPTURE_ERR_OK) {
        LOGW("SetErrorCallback failed code=%{public}d", static_cast<int32_t>(err));
    }

    err = OH_AVScreenCapture_SetDataCallback(capture_, &KeepAliveCapture::OnBufferAvailable, this);
    if (err != AV_SCREEN_CAPTURE_ERR_OK) {
        LOGE("SetDataCallback failed code=%{public}d", static_cast<int32_t>(err));
        lastStage_.store(KA_STAGE_INIT_FAILED);
        ReleaseLocked();
        return KA_STAGE_INIT_FAILED;
    }

    // 本场景不请求麦克风；明确设为 false，避免隐私录音与不必要权限。
    err = OH_AVScreenCapture_SetMicrophoneEnabled(capture_, micEnabled);
    if (err != AV_SCREEN_CAPTURE_ERR_OK) {
        LOGW("SetMicrophoneEnabled(%{public}d) failed code=%{public}d",
             micEnabled ? 1 : 0, static_cast<int32_t>(err));
        if (micEnabled) {
            lastStage_.store(KA_STAGE_INIT_FAILED);
            ReleaseLocked();
            return KA_STAGE_INIT_FAILED;
        }
    }

    ApplyPickerStrategy();

    err = OH_AVScreenCapture_StartScreenCapture(capture_);
    if (err != AV_SCREEN_CAPTURE_ERR_OK) {
        LOGE("audio-only StartScreenCapture failed code=%{public}d", static_cast<int32_t>(err));
        lastStage_.store(KA_STAGE_START_FAILED);
        ReleaseLocked();
        return KA_STAGE_START_FAILED;
    }

    started_.store(true);
    running_.store(true);
    lastStage_.store(KA_STAGE_OK);
    LOGI("audio-only capture started: inner=48000Hz stereo, mic=%{public}d, video=off",
         micEnabled ? 1 : 0);
    return KA_STAGE_OK;
}

void KeepAliveCapture::Stop() {
    std::lock_guard<std::mutex> guard(lock_);
    if (capture_ == nullptr) {
        running_.store(false);
        std::lock_guard<std::mutex> callbackGuard(callbackLock_);
        onAudioFrame_ = nullptr;
        return;
    }
    running_.store(false);
    ReleaseLocked();
    LOGI("audio-only capture stopped");
}

KeepAliveSnapshot KeepAliveCapture::Snapshot() const {
    KeepAliveSnapshot s{};
    s.running = running_.load() ? 1 : 0;
    s.micEnabled = micEnabled_.load() ? 1 : 0;
    s.innerBuffers = innerBuffers_.load();
    s.micBuffers = micBuffers_.load();
    s.videoBuffers = videoBuffers_.load();
    s.lastStage = lastStage_.load();
    s.interrupted = interrupted_.load();
    return s;
}

void KeepAliveCapture::OnState(OH_AVScreenCapture *capture,
                               OH_AVScreenCaptureStateCode stateCode,
                               void *userData) {
    (void)capture;
    auto *self = static_cast<KeepAliveCapture *>(userData);
    if (self == nullptr) {
        return;
    }

    switch (stateCode) {
        case OH_SCREEN_CAPTURE_STATE_STARTED:
            LOGI("audio-only capture state=STARTED");
            break;
        case OH_SCREEN_CAPTURE_STATE_MIC_UNAVAILABLE:
        case OH_SCREEN_CAPTURE_STATE_MIC_MUTED_BY_USER:
        case OH_SCREEN_CAPTURE_STATE_MIC_UNMUTED_BY_USER:
        case OH_SCREEN_CAPTURE_STATE_ENTER_PRIVATE_SCENE:
        case OH_SCREEN_CAPTURE_STATE_EXIT_PRIVATE_SCENE:
        case OH_SCREEN_CAPTURE_STATE_STOPPED_BY_USER_SWITCHES:
        case OH_SCREEN_CAPTURE_STATE_PAUSED_BY_USER:
        case OH_SCREEN_CAPTURE_STATE_RESUMED_BY_USER:
        case OH_SCREEN_CAPTURE_STATE_PAUSED_BY_APP:
        case OH_SCREEN_CAPTURE_STATE_RESUMED_BY_APP:
            // These state transitions do not themselves prove that inner playback capture ended.
            LOGI("audio-only capture state=%{public}d", static_cast<int32_t>(stateCode));
            break;
        case OH_SCREEN_CAPTURE_STATE_CANCELED:
        case OH_SCREEN_CAPTURE_STATE_STOPPED_BY_USER:
        case OH_SCREEN_CAPTURE_STATE_STOPPED_BY_CALL:
        case OH_SCREEN_CAPTURE_STATE_INTERRUPTED_BY_OTHER:
            self->interrupted_.store(1);
            self->running_.store(false);
            LOGW("audio-only capture terminated state=%{public}d", static_cast<int32_t>(stateCode));
            break;
        default:
            LOGI("audio-only capture state=%{public}d", static_cast<int32_t>(stateCode));
            break;
    }
}

void KeepAliveCapture::OnError(OH_AVScreenCapture *capture, int32_t errorCode, void *userData) {
    (void)capture;
    auto *self = static_cast<KeepAliveCapture *>(userData);
    if (self == nullptr) {
        return;
    }
    self->interrupted_.store(1);
    self->running_.store(false);
    LOGE("audio-only capture error=%{public}d", errorCode);
}

void KeepAliveCapture::OnBufferAvailable(OH_AVScreenCapture *capture, OH_AVBuffer *buffer,
                                         OH_AVScreenCaptureBufferType bufferType,
                                         int64_t timestamp, void *userData) {
    (void)capture;
    auto *self = static_cast<KeepAliveCapture *>(userData);
    if (self == nullptr || buffer == nullptr) {
        return;
    }

    if (bufferType == OH_SCREEN_CAPTURE_BUFFERTYPE_AUDIO_INNER) {
        const int64_t count = self->innerBuffers_.fetch_add(1) + 1;
        if (count <= 2 || count % 500 == 0) {
            LOGI("inner playback PCM buffer #%{public}lld ts=%{public}lld",
                 static_cast<long long>(count), static_cast<long long>(timestamp));
        }
    } else if (bufferType == OH_SCREEN_CAPTURE_BUFFERTYPE_AUDIO_MIC) {
        const int64_t count = self->micBuffers_.fetch_add(1) + 1;
        if (count <= 2) {
            LOGW("microphone buffer received while micEnabled=%{public}d",
                 self->micEnabled_.load() ? 1 : 0);
        }
        if (!self->micEnabled_.load()) {
            return;
        }
    } else if (bufferType == OH_SCREEN_CAPTURE_BUFFERTYPE_VIDEO) {
        const int64_t count = self->videoBuffers_.fetch_add(1) + 1;
        if (count <= 2) {
            LOGW("unexpected video buffer in audio-only capture #%{public}lld",
                 static_cast<long long>(count));
        }
        return;
    } else {
        return;
    }

    OH_AVCodecBufferAttr attr{};
    const OH_AVErrCode attrErr = OH_AVBuffer_GetBufferAttr(buffer, &attr);
    if (attrErr != AV_ERR_OK || attr.size <= 0 || attr.offset < 0) {
        return;
    }

    const int32_t capacity = OH_AVBuffer_GetCapacity(buffer);
    const uint8_t *addr = OH_AVBuffer_GetAddr(buffer);
    const int64_t end = static_cast<int64_t>(attr.offset) + attr.size;
    if (addr == nullptr || capacity < 0 || end > capacity) {
        LOGW("invalid audio buffer range offset=%{public}d size=%{public}d capacity=%{public}d",
             attr.offset, attr.size, capacity);
        return;
    }

    AudioCallback callback;
    {
        std::lock_guard<std::mutex> callbackGuard(self->callbackLock_);
        callback = self->onAudioFrame_;
    }
    if (!callback) {
        return;
    }

    CapturedAudioFrame frame{};
    frame.data.assign(addr + attr.offset, addr + attr.offset + attr.size);
    frame.timestampUs = attr.pts > 0 ? attr.pts : timestamp / 1000;
    frame.sourceType = static_cast<int32_t>(bufferType);
    callback(frame);
}

void KeepAliveCapture::ApplyPickerStrategy() {
    if (capture_ == nullptr) {
        return;
    }

    OH_AVScreenCapture_CaptureStrategy *strategy = OH_AVScreenCapture_CreateCaptureStrategy();
    if (strategy == nullptr) {
        LOGW("CreateCaptureStrategy failed; keep system default picker behavior");
        return;
    }

    const OH_AVSCREEN_CAPTURE_ErrCode pickerErr =
        OH_AVScreenCapture_StrategyForPickerPopUp(strategy, false);
    if (pickerErr != AV_SCREEN_CAPTURE_ERR_OK) {
        LOGW("StrategyForPickerPopUp(false) failed code=%{public}d", static_cast<int32_t>(pickerErr));
    }

    const OH_AVSCREEN_CAPTURE_ErrCode setErr = OH_AVScreenCapture_SetCaptureStrategy(capture_, strategy);
    if (setErr != AV_SCREEN_CAPTURE_ERR_OK) {
        LOGW("SetCaptureStrategy failed code=%{public}d", static_cast<int32_t>(setErr));
    }
    OH_AVScreenCapture_ReleaseCaptureStrategy(strategy);
}

void KeepAliveCapture::ReleaseLocked() {
    if (capture_ != nullptr) {
        if (started_.exchange(false)) {
            OH_AVScreenCapture_StopScreenCapture(capture_);
        }
        OH_AVScreenCapture_Release(capture_);
        capture_ = nullptr;
    }
    running_.store(false);
    std::lock_guard<std::mutex> callbackGuard(callbackLock_);
    onAudioFrame_ = nullptr;
}

} // namespace carhi
