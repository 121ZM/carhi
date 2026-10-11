/*
 * CarLife 手机端采集编码管线（Native）
 *
 * 数据流（全程零拷贝，画面不经 CPU 搬移）：
 *
 *   OH_AVScreenCapture ──Surface──▶ OH_VideoEncoder ──H.264 NALU──▶ JS 回调
 *
 * 关键设计：
 *   - 采集侧用 StartScreenCaptureWithSurface，把采集输出直接送进编码器的输入
 *     Surface，避免"取帧 -> 拷到输入缓冲"这条 CPU 路径。
 *   - 编码参数按车机 98311 下发的分辨率/帧率设置（协议要求编码参数由车机定）。
 *   - Profile 用 Baseline：无 B 帧、无 CABAC 依赖，安卓 4.4 老车机的硬解最稳。
 *   - 开 OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY，压低首帧与端到端延迟。
 */

#ifndef CARHI_SCREEN_ENCODER_H
#define CARHI_SCREEN_ENCODER_H

#include <atomic>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <thread>

#include <multimedia/player_framework/native_avcodec_videoencoder.h>
#include <multimedia/player_framework/native_avscreen_capture.h>
#include <multimedia/player_framework/native_avscreen_capture_base.h>
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

/** 编码参数 */
struct EncoderParams {
    int32_t width = 1280;
    int32_t height = 720;
    int32_t frameRate = 30;
    int32_t bitrate = 4000000;   // bit/s
    int32_t iFrameIntervalMs = 2000;
};

/**
 * 采集 + 编码管线。
 * 生命周期：Start() -> ... -> Stop()，Stop 可重复调用。
 * 线程模型：Start/Stop 在调用者线程；编码输出回调在编解码器线程，
 *          由上层（napi_init）负责转投到 JS 线程。
 */
class ScreenEncoder {
public:
    using FrameCallback = std::function<void(const EncodedFrame &frame)>;
    using ErrorCallback = std::function<void(int32_t code, const std::string &msg)>;
    using LogCallback = std::function<void(const std::string &msg)>;

    ScreenEncoder() = default;
    ~ScreenEncoder();

    ScreenEncoder(const ScreenEncoder &) = delete;
    ScreenEncoder &operator=(const ScreenEncoder &) = delete;

    /**
     * 启动采集与编码。
     * @return 0 成功；非 0 为失败阶段编码（见实现内注释）
     */
    int32_t Start(const EncoderParams &params, FrameCallback onFrame,
                  ErrorCallback onError, LogCallback onLog);

    /** 停止并释放全部资源（幂等） */
    void Stop();

    /** 请求立即编一个 I 帧（车机刚连上时用，避免等一个 GOP） */
    void RequestKeyFrame();

    bool IsRunning() const { return running_.load(); }

    /** 编码器输出的宽高（可能与请求值不同，编码器会按对齐调整） */
    int32_t EncodedWidth() const { return encodedWidth_.load(); }
    int32_t EncodedHeight() const { return encodedHeight_.load(); }

private:
    // ---- 编码器回调（静态，转实例方法） ----
    static void OnCodecError(OH_AVCodec *codec, int32_t errorCode, void *userData);
    static void OnStreamChanged(OH_AVCodec *codec, OH_AVFormat *format, void *userData);
    static void OnNeedInputBuffer(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData);
    static void OnNewOutputBuffer(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData);

    // ---- 采集回调（静态，转实例方法） ----
    static void OnCaptureState(OH_AVScreenCapture *capture, OH_AVScreenCaptureStateCode stateCode, void *userData);
    static void OnCaptureError(OH_AVScreenCapture *capture, int32_t errorCode, void *userData);

    void HandleNewOutputBuffer(uint32_t index, OH_AVBuffer *buffer);
    void EmitError(int32_t code, const std::string &msg);

    /** 释放编码器相关资源 */
    void ReleaseCodec();
    /** 释放采集相关资源 */
    void ReleaseCapture();

private:
    std::atomic<bool> running_{false};
    std::atomic<bool> codecStarted_{false};
    std::atomic<bool> captureStarted_{false};
    std::atomic<int32_t> encodedWidth_{0};
    std::atomic<int32_t> encodedHeight_{0};
    std::atomic<bool> forceKeyFrame_{false};

    EncoderParams params_{};
    FrameCallback onFrame_;
    ErrorCallback onError_;
    LogCallback onLog_;

    OH_AVCodec *codec_ = nullptr;
    OH_AVScreenCapture *capture_ = nullptr;
    OHNativeWindow *encoderSurface_ = nullptr;

    std::mutex lock_;
};

} // namespace carhi

#endif // CARHI_SCREEN_ENCODER_H
