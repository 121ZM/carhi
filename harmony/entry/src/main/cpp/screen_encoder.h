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

// ★ 复用 canvas_encoder.h 里的公共类型（EncodedFrame / EncoderParams）。
//   两者字段完全一致，各定义一份会在同时 include 时报 `redefinition`
//   （2026-10-15 恢复录屏代码时踩到）。合并成一个定义是唯一合理做法。
#include "canvas_encoder.h"

namespace carhi {

/**
 * 采集中断的错误码约定（负值，与系统 errno 区分开）
 *
 * 关键区分：
 *   "用户主动停止" —— 用户明确取消授权/主动停止，重试没有意义，上层应停流。
 *   "系统临时打断" —— 切后台、来电、其他应用抢占，重试通常能恢复，上层应重启采集。
 */
enum CaptureInterrupt {
    /** 用户在授权弹窗点了"取消" —— 致命，重试会再次弹窗骚扰用户 */
    INTERRUPT_CANCELED_BY_USER = -1,
    /** 用户主动停止采集 —— 致命 */
    INTERRUPT_STOPPED_BY_USER = -2,
    /** 来电打断 —— 可恢复（通话结束后可继续） */
    INTERRUPT_STOPPED_BY_CALL = -3,
    /** 被其他应用/系统抢占 —— 可恢复 */
    INTERRUPT_BY_OTHER = -4,
    /** 底层采集错误 —— 可恢复（多数为临时性） */
    INTERRUPT_CAPTURE_ERROR = -5,
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

    /**
     * 运行中动态调整编码帧率（车机下发 98316 时调用）。
     *
     * 走 OH_VideoEncoder_SetParameter 的软刷新路径，**不重建管线** ——
     * 重建会强制更换 Surface 并让车机侧重新等待 I 帧，表现为掉线。
     *
     * @return 0 成功；非 0 失败
     */
    int32_t SetFrameRate(int32_t frameRate);

    /**
     * 仅重启屏幕采集（编码器保持存活）。
     *
     * 用途：切后台/来电/被其他应用抢占导致采集被系统掐断后，不必销毁整个
     * 编码管线，只重建采集侧即可恢复出帧。相比完整 Stop()+Start()，
     * 这条路径不会重置编码器的码率控制状态，恢复更快、画面更稳。
     *
     * @return 0 成功；非 0 为 StartStage 阶段号
     */
    int32_t RestartCapture();

    bool IsRunning() const { return running_.load(); }

    /** 判定某个中断码是否值得重试（可恢复） */
    static bool IsRecoverable(int32_t code);

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
    /**
     * ★ 采集数据回调（音频/视频 buffer 可用时触发）。
     *
     * 为什么要注册它：长时任务 `AUDIO_RECORDING` 的语义是"音频录制正在进行"。
     * 若只配置参数、无人消费数据，系统可能判定"音频录制未进行"而**挂起任务**
     * （SYSTEM_SUSPEND_AUDIO_RECORDING_NOT_RUNNING = 7）→ 任务挂起后应用一切到后台
     * 就被冻结 → 采集与心跳全停 → 车机 5 秒超时断开（「投屏切应用掉线」）。
     * 这里把内录音频真正消费掉，让任务名实相符。
     *
     * ⚠ 官方语义：注册本回调后，OH_AVScreenCapture_AcquireAudioBuffer /
     * ReleaseAudioBuffer / AcquireVideoBuffer / ReleaseVideoBuffer 都会**返回失败**；
     * buffer 由系统在回调返回后自动失效，**不需要也不允许手动释放**。
     */
    static void OnCaptureBufferAvailable(OH_AVScreenCapture *capture, OH_AVBuffer *buffer,
                                         OH_AVScreenCaptureBufferType bufferType,
                                         int64_t timestamp, void *userData);

    void HandleNewOutputBuffer(uint32_t index, OH_AVBuffer *buffer);
    void EmitError(int32_t code, const std::string &msg);

    /**
     * 创建并启动屏幕采集（假定编码器已就绪）。
     * 必须在持有 lock_ 的前提下调用。
     * @return 0 成功；非 0 为 StartStage 阶段号
     */
    int32_t StartCaptureLocked();

    /**
     * 在采集启动前设置 OH_AVScreenCapture_CaptureStrategy。
     * 必须在 StartScreenCapture* 之前调用；失败仅记日志，不阻断采集。
     */
    void ApplyCaptureStrategyLocked();

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

    /** ★ 内录音频 buffer 计数 —— 证明"音频录制确实在进行"（长时任务保活的关键） */
    std::atomic<uint64_t> audioInnerBuffers_{0};
    /** 麦克风音频 buffer 计数（已关麦克风，正常应恒为 0） */
    std::atomic<uint64_t> audioMicBuffers_{0};
    /** 采集侧视频 buffer 计数（surface 模式下应恒为 0） */
    std::atomic<uint64_t> videoBuffers_{0};

    EncoderParams params_{};
    FrameCallback onFrame_;
    ErrorCallback onError_;
    LogCallback onLog_;

    OH_AVCodec *codec_ = nullptr;
    OH_AVScreenCapture *capture_ = nullptr;
    OHNativeWindow *encoderSurface_ = nullptr;

    /**
     * 上一次采集重启的时间点（steady_clock 毫秒）。
     * 用于抑制"重启 → 系统又报状态 → 又重启"的震荡：
     * 编码器 Surface 每次重建都会让车机侧丢一段流，所以重启必须低频。
     */
    int64_t lastRestartMs_ = 0;

    std::mutex lock_;
};

} // namespace carhi

#endif // CARHI_SCREEN_ENCODER_H
