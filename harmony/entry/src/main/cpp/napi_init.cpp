/*
 * CarLife 手机端 Native 模块（NAPI）
 *
 * 对外接口（供 ArkTS 调用）：
 *   startCapture(options, onFrame, onError): number
 *   stopCapture(): void
 *   requestKeyFrame(): void
 *   isRunning(): boolean
 *
 * 线程模型：
 *   编码器输出回调跑在编解码器线程，不能直接调 JS。这里用
 *   napi_threadsafe_function 把帧投递到 JS 线程。
 *
 * 背压策略：
 *   帧队列有界（kFrameQueueSize），满时**丢帧并请求一个 I 帧**，
 *   而不是无限排队（会吃爆内存）或阻塞编码器线程（会让整条管线停摆）。
 *   丢帧后立刻补 I 帧，车机侧最多花一个 I 帧周期恢复画面。
 */

#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include <hilog/log.h>
#include <napi/native_api.h>

#include "screen_encoder.h"

#define LOG_DOMAIN 0x0001
#define LOG_TAG "CarHiNative"
#define LOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)

namespace {

/** 帧队列上限：约 1 秒的量（30fps），超过说明下游堵了，丢帧比堆积好 */
constexpr size_t kFrameQueueSize = 32;

/** 投递到 JS 线程的帧任务 */
struct FrameTask {
    std::vector<uint8_t> data;
    int64_t pts = 0;
    bool keyFrame = false;
};

/** 投递到 JS 线程的错误任务 */
struct ErrorTask {
    int32_t code = 0;
    std::string message;
};

napi_threadsafe_function g_frameTsfn = nullptr;
napi_threadsafe_function g_errorTsfn = nullptr;
std::unique_ptr<carhi::ScreenEncoder> g_encoder;
std::mutex g_lock;

// ---------------------------------------------------------------------------
// JS 线程侧：实际调用 JS 回调
// ---------------------------------------------------------------------------

void CallFrameJs(napi_env env, napi_value jsCallback, void * /*context*/, void *data) {
    std::unique_ptr<FrameTask> task(static_cast<FrameTask *>(data));
    if (env == nullptr || jsCallback == nullptr || task == nullptr) {
        return;
    }

    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);

    // 把 H.264 数据拷进 ArrayBuffer 交给 JS（缓冲随后就被编码器回收，
    // 不能只传指针）
    void *raw = nullptr;
    napi_value buffer = nullptr;
    if (napi_create_arraybuffer(env, task->data.size(), &raw, &buffer) != napi_ok) {
        return;
    }
    if (!task->data.empty() && raw != nullptr) {
        std::memcpy(raw, task->data.data(), task->data.size());
    }

    napi_value pts = nullptr;
    napi_create_int64(env, task->pts, &pts);
    napi_value keyFrame = nullptr;
    napi_get_boolean(env, task->keyFrame, &keyFrame);

    napi_value argv[3] = {buffer, pts, keyFrame};
    napi_value result = nullptr;
    napi_call_function(env, undefined, jsCallback, 3, argv, &result);
}

void CallErrorJs(napi_env env, napi_value jsCallback, void * /*context*/, void *data) {
    std::unique_ptr<ErrorTask> task(static_cast<ErrorTask *>(data));
    if (env == nullptr || jsCallback == nullptr || task == nullptr) {
        return;
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);

    napi_value code = nullptr;
    napi_create_int32(env, task->code, &code);
    napi_value message = nullptr;
    napi_create_string_utf8(env, task->message.c_str(), NAPI_AUTO_LENGTH, &message);

    napi_value argv[2] = {code, message};
    napi_value result = nullptr;
    napi_call_function(env, undefined, jsCallback, 2, argv, &result);
}

// ---------------------------------------------------------------------------
// 编码管线回调（编解码器线程）
// ---------------------------------------------------------------------------

void OnFrame(const carhi::EncodedFrame &frame) {
    if (g_frameTsfn == nullptr) {
        return;
    }
    auto task = std::make_unique<FrameTask>();
    task->data.assign(frame.data, frame.data + frame.size);
    task->pts = frame.pts;
    task->keyFrame = frame.keyFrame;

    // 非阻塞投递：队列满说明下游消费不过来，丢帧并补 I 帧
    napi_status status = napi_call_threadsafe_function(g_frameTsfn, task.get(), napi_tsfn_nonblocking);
    if (status == napi_ok) {
        task.release();   // 所有权交给 JS 线程
    } else {
        LOGE("frame queue full, dropping frame (%{public}d bytes)", frame.size);
        if (g_encoder != nullptr) {
            g_encoder->RequestKeyFrame();
        }
    }
}

void OnError(int32_t code, const std::string &msg) {
    if (g_errorTsfn == nullptr) {
        return;
    }
    auto task = std::make_unique<ErrorTask>();
    task->code = code;
    task->message = msg;
    napi_status status = napi_call_threadsafe_function(g_errorTsfn, task.get(), napi_tsfn_nonblocking);
    if (status == napi_ok) {
        task.release();
    }
}

void OnLog(const std::string &msg) {
    LOGI("%{public}s", msg.c_str());
}

// ---------------------------------------------------------------------------
// NAPI 参数解析辅助
// ---------------------------------------------------------------------------

bool GetIntProp(napi_env env, napi_value obj, const char *key, int32_t fallback, int32_t *out) {
    *out = fallback;
    bool has = false;
    if (napi_has_named_property(env, obj, key, &has) != napi_ok || !has) {
        return false;
    }
    napi_value value = nullptr;
    if (napi_get_named_property(env, obj, key, &value) != napi_ok) {
        return false;
    }
    int32_t parsed = 0;
    if (napi_get_value_int32(env, value, &parsed) != napi_ok) {
        return false;
    }
    *out = parsed;
    return true;
}

// ---------------------------------------------------------------------------
// 导出接口
// ---------------------------------------------------------------------------

napi_value StartCapture(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 2) {
        napi_throw_type_error(env, nullptr, "startCapture requires (options, onFrame, onError?)");
        return nullptr;
    }

    std::lock_guard<std::mutex> guard(g_lock);
    if (g_encoder != nullptr && g_encoder->IsRunning()) {
        LOGI("already running");
        napi_value zero = nullptr;
        napi_create_int32(env, 0, &zero);
        return zero;
    }

    carhi::EncoderParams params{};
    GetIntProp(env, args[0], "width", params.width, &params.width);
    GetIntProp(env, args[0], "height", params.height, &params.height);
    GetIntProp(env, args[0], "frameRate", params.frameRate, &params.frameRate);
    GetIntProp(env, args[0], "bitrate", params.bitrate, &params.bitrate);
    GetIntProp(env, args[0], "iFrameIntervalMs", params.iFrameIntervalMs, &params.iFrameIntervalMs);

    // 分辨率做基本合法性检查，避免把非法值喂给编码器
    if (params.width < 128 || params.height < 128) {
        params.width = 1280;
        params.height = 720;
    }
    if (params.frameRate < 1 || params.frameRate > 60) {
        params.frameRate = 30;
    }
    if (params.bitrate < 100000) {
        params.bitrate = 4000000;
    }

    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "CarLifeFrame", NAPI_AUTO_LENGTH, &resourceName);

    napi_status status = napi_create_threadsafe_function(
        env, args[1], nullptr, resourceName, kFrameQueueSize, 1, nullptr, nullptr, nullptr,
        CallFrameJs, &g_frameTsfn);
    if (status != napi_ok || g_frameTsfn == nullptr) {
        napi_throw_error(env, nullptr, "failed to create frame callback bridge");
        return nullptr;
    }

    // 错误回调可选
    bool hasErrorCb = false;
    napi_valuetype errorType = napi_undefined;
    if (argc >= 3 && args[2] != nullptr) {
        napi_typeof(env, args[2], &errorType);
        hasErrorCb = (errorType == napi_function);
    }
    if (hasErrorCb) {
        napi_value errName = nullptr;
        napi_create_string_utf8(env, "CarLifeError", NAPI_AUTO_LENGTH, &errName);
        napi_create_threadsafe_function(env, args[2], nullptr, errName, 8, 1, nullptr, nullptr, nullptr,
                                        CallErrorJs, &g_errorTsfn);
    }

    g_encoder = std::make_unique<carhi::ScreenEncoder>();
    int32_t stage = g_encoder->Start(params, OnFrame, OnError, OnLog);
    if (stage != 0) {
        LOGE("pipeline start failed at stage %{public}d", stage);
        g_encoder.reset();
        if (g_frameTsfn != nullptr) {
            napi_release_threadsafe_function(g_frameTsfn, napi_tsfn_release);
            g_frameTsfn = nullptr;
        }
        if (g_errorTsfn != nullptr) {
            napi_release_threadsafe_function(g_errorTsfn, napi_tsfn_release);
            g_errorTsfn = nullptr;
        }
    }

    napi_value result = nullptr;
    napi_create_int32(env, stage, &result);
    return result;
}

napi_value StopCapture(napi_env env, napi_callback_info info) {
    (void)info;
    std::lock_guard<std::mutex> guard(g_lock);

    if (g_encoder != nullptr) {
        g_encoder->Stop();
        g_encoder.reset();
    }
    if (g_frameTsfn != nullptr) {
        napi_release_threadsafe_function(g_frameTsfn, napi_tsfn_release);
        g_frameTsfn = nullptr;
    }
    if (g_errorTsfn != nullptr) {
        napi_release_threadsafe_function(g_errorTsfn, napi_tsfn_release);
        g_errorTsfn = nullptr;
    }

    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

napi_value RequestKeyFrame(napi_env env, napi_callback_info info) {
    (void)info;
    std::lock_guard<std::mutex> guard(g_lock);
    if (g_encoder != nullptr) {
        g_encoder->RequestKeyFrame();
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

napi_value IsRunning(napi_env env, napi_callback_info info) {
    (void)info;
    bool running = false;
    {
        std::lock_guard<std::mutex> guard(g_lock);
        running = (g_encoder != nullptr) && g_encoder->IsRunning();
    }
    napi_value result = nullptr;
    napi_get_boolean(env, running, &result);
    return result;
}

napi_value EncodedSize(napi_env env, napi_callback_info info) {
    (void)info;
    int32_t w = 0;
    int32_t h = 0;
    {
        std::lock_guard<std::mutex> guard(g_lock);
        if (g_encoder != nullptr) {
            w = g_encoder->EncodedWidth();
            h = g_encoder->EncodedHeight();
        }
    }
    napi_value result = nullptr;
    napi_create_object(env, &result);
    napi_value width = nullptr;
    napi_value height = nullptr;
    napi_create_int32(env, w, &width);
    napi_create_int32(env, h, &height);
    napi_set_named_property(env, result, "width", width);
    napi_set_named_property(env, result, "height", height);
    return result;
}

} // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"startCapture", nullptr, StartCapture, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopCapture", nullptr, StopCapture, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"requestKeyFrame", nullptr, RequestKeyFrame, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isRunning", nullptr, IsRunning, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"encodedSize", nullptr, EncodedSize, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module carlifeCodecModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "carlifecodec",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterCarLifeCodecModule(void) {
    napi_module_register(&carlifeCodecModule);
}
