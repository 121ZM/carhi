/*
 * CarHi 后台保活采集会话（音频专用，Native）
 *
 * ## 它解决什么问题
 *
 * 长时任务 `AUDIO_RECORDING` 的判据不是"任务注册了"，而是
 * **"真的有音频采集会话在跑"**（2026-10-16 真机定案，见工作区记忆 §16）。
 * 会话在 → 系统给 `Doze has special:ERR_HAS_CONTINUOUS_TASK` 豁免冻结；
 * 从来没有 → 系统进后台 **+2 秒**就 `Freeze pid` 并
 * `StandbyExecutor: [BreakSocketsPid] Destroyed 7 sockets`（= CarLife 掉线）。
 *
 * 两条画面通路里，「应用投屏」自带一份采集（含音频），所以它是安全的；
 * 而「native 自绘」（HmiRenderer 画进编码器 surface）**完全没有采集会话**
 * —— 这正是自绘模式切后台必掉的根因。
 *
 * 本类就是给自绘模式补上那个"音频采集会话"：**只采内录、不采屏幕、不开麦**。
 *
 * ## 官方依据（不是 hack）
 *
 * `native_avscreen_capture.h:64-74` 原文：
 *   - 「In the scenario where screen capture streams are generated, the application
 *      must ensure that **either audio sampling parameters for internal capture or
 *      video sampling parameters are valid, or both are valid**, and audio sampling
 *      parameters for external capture using microphones are valid (**optional**).」
 *   - 「If both **videoFrameWidth** and **videoFrameHeight** ... are **0**, the
 *      OH_AVScreenCapture instance ignores the corresponding video parameters and
 *      **does not collect the screen data**.」
 *
 * ⇒ 「内录参数有效 + 视频参数为 0 + 不开麦」是官方明确支持的组合。
 *
 * ## 与 ScreenEncoder 的关系
 *
 * **互斥、不共存**：本类只在自绘/兜底模式下起，那时 `ScreenEncoder` 没在跑
 * （它由 `ScreenCaptureSource` 在应用投屏模式下持有）。上层负责保证这一点。
 *
 * ## 数据去哪了
 *
 * **直接丢弃**。它的唯一使命是"让系统看见一个活着的音频采集会话"。
 * 内录数据本身不接 CarLife —— CarLife 的音频走 **A2DP 蓝牙**，不走 TCP
 * （`CarlifeBTAudioInfoProto.supportBtAudio` / `huBtAudioSupport`）。
 */

#ifndef CARHI_KEEPALIVE_CAPTURE_H
#define CARHI_KEEPALIVE_CAPTURE_H

#include <atomic>
#include <cstdint>
#include <functional>
#include <mutex>
#include <vector>

#include <multimedia/player_framework/native_avscreen_capture.h>
#include <multimedia/player_framework/native_avscreen_capture_base.h>

namespace carhi {

/**
 * 保活采集的失败阶段码。
 *
 * 从 **51** 起，远离 `canvas_encoder.h` 的 `StartStage`(0~7)、
 * `screen_encoder.cpp` 的 `CaptureStartStage`(17~19)、HMI 的 8/9 ——
 * 上层拿一个数字就能判断是哪条通路挂在哪一步。
 */
enum KeepAliveStage {
    KA_STAGE_OK = 0,
    /** OH_AVScreenCapture_Create 失败 */
    KA_STAGE_CREATE_FAILED = 51,
    /** OH_AVScreenCapture_Init 失败（参数被拒；多因隐私授权或参数组合非法） */
    KA_STAGE_INIT_FAILED = 52,
    /** OH_AVScreenCapture_StartScreenCapture 失败（多因用户未授权/被拒） */
    KA_STAGE_START_FAILED = 53,
    /** 已经在跑（Start 幂等返回） */
    KA_STAGE_ALREADY_RUNNING = 54,
};

/** 一帧已复制出的原始音频数据（采集回调 buffer 失效前复制） */
struct CapturedAudioFrame {
    std::vector<uint8_t> data;
    /** 音频 PTS，微秒 */
    int64_t timestampUs = 0;
    /** OH_AVScreenCaptureBufferType：1=内录，2=麦克风 */
    int32_t sourceType = 0;
};

/** 保活会话诊断快照（给 ArkTS 侧展示） */
struct KeepAliveSnapshot {
    /** 会话是否在跑 */
    int32_t running = 0;
    /** 是否开了麦克风（0/1）—— 开麦会常驻隐私指示点，默认关 */
    int32_t micEnabled = 0;
    /** 累计收到的内录音频 buffer 数 —— **这是"会话活着"的直接证据** */
    int64_t innerBuffers = 0;
    /** 累计收到的麦克风 buffer 数（未开麦时应恒为 0） */
    int64_t micBuffers = 0;
    /** 累计收到的视频 buffer 数（本类不采屏，应恒为 0） */
    int64_t videoBuffers = 0;
    /** 最近一次启动的阶段码（0 = 成功） */
    int32_t lastStage = 0;
    /** 会话是否曾被系统打断过（用来区分"从没起来"和"起来又没了"） */
    int32_t interrupted = 0;
};

/**
 * 「只采内录」的保活采集会话。
 * 生命周期：Start() -> ... -> Stop()，Stop 幂等，可反复 Start/Stop。
 * 线程模型：Start/Stop 在调用者线程；回调在采集线程，只做原子计数 + 打日志。
 */
class KeepAliveCapture {
public:
    KeepAliveCapture() = default;
    ~KeepAliveCapture();

    KeepAliveCapture(const KeepAliveCapture &) = delete;
    KeepAliveCapture &operator=(const KeepAliveCapture &) = delete;

    /**
     * 启动保活采集会话。
     *
     * @param micEnabled 是否同时开麦克风。
     *   - `false`（默认，推荐）：只采内录，**不弹麦克风隐私指示点**。
     *     依据 2026-10-16 12:19 窗口的现场证据（mic 关、只有内录，任务仍被豁免）。
     *   - `true`：额外开麦。若 `false` 在真机上不足以豁免冻结，用它做 A/B。
     *     ⚠️ 代价：状态栏常驻麦克风指示点，且后台应用激活麦克风在部分版本被禁
     *     （`native_avscreen_capture.h:646` 原文：the audio module does not allow
     *      background applications to activate microphone recording）。
     *
     * @return 0 成功；非 0 见 KeepAliveStage
     */
    using AudioCallback = std::function<void(const CapturedAudioFrame &frame)>;

    int32_t Start(bool micEnabled, AudioCallback onAudioFrame);

    /** 停止并释放（幂等） */
    void Stop();

    bool IsRunning() const { return running_.load(); }

    /** 诊断快照（线程安全） */
    KeepAliveSnapshot Snapshot() const;

private:
    // ---- 采集回调（静态，转实例方法） ----
    static void OnState(OH_AVScreenCapture *capture, OH_AVScreenCaptureStateCode stateCode,
                        void *userData);
    static void OnError(OH_AVScreenCapture *capture, int32_t errorCode, void *userData);
    static void OnBufferAvailable(OH_AVScreenCapture *capture, OH_AVBuffer *buffer,
                                  OH_AVScreenCaptureBufferType bufferType,
                                  int64_t timestamp, void *userData);

    /** 关掉"启动后统一弹 Picker"，让会话能在无人值守下起来（失败仅记日志） */
    void ApplyPickerStrategy();

    /** 释放采集实例（调用者须持有 lock_） */
    void ReleaseLocked();

private:
    mutable std::mutex lock_;
    std::mutex callbackLock_;
    AudioCallback onAudioFrame_;
    OH_AVScreenCapture *capture_ = nullptr;

    std::atomic<bool> running_{false};
    std::atomic<bool> started_{false};
    std::atomic<bool> micEnabled_{false};

    std::atomic<int64_t> innerBuffers_{0};
    std::atomic<int64_t> micBuffers_{0};
    std::atomic<int64_t> videoBuffers_{0};
    std::atomic<int32_t> lastStage_{KA_STAGE_OK};
    std::atomic<int32_t> interrupted_{0};
};

} // namespace carhi

#endif // CARHI_KEEPALIVE_CAPTURE_H
