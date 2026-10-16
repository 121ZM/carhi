/*
 * CarHi Native 模块（NAPI）—— 路线 A：自绘画面，不走录屏
 *
 * 对外接口（供 ArkTS 调用）：
 *   startEncoder(surfaceId, options, onFrame, onError): number
 *   attachSurface(surfaceId): number
 *   stopEncoder(): void
 *   requestKeyFrame(): void
 *   setFrameRate(fps): number
 *   isRunning(): boolean
 *   encodedSize(): {width, height}
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
#include <multimedia/image_framework/image/pixelmap_native.h>

#include "canvas_encoder.h"
#include "hmi_renderer.h"
#include "pipeline_probe.h"
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
std::unique_ptr<carhi::CanvasEncoder> g_encoder;
std::unique_ptr<carhi::HmiRenderer> g_hmi;

/**
 * ★ 录屏画面源（应用投屏）—— 与 `g_encoder`（自绘/截图用的编码器）**互斥**。
 *
 * 为什么独立变量而不是复用 `g_encoder`：
 *   `ScreenEncoder` 是「采集 → 编码 → 出帧」一体化对象（自带 OH_AVScreenCapture
 *   和 OH_VideoEncoder），与 `CanvasEncoder`（只管编码，画面由外部喂）职责不同。
 *   两者都占用编码器资源，**同一时刻只能跑一个** —— 由上层（ArkTS）保证互斥。
 *
 * 历史：2026-10-12 首次实现，2026-10-15 因误判「切后台停摆」删除，
 *       同日经大哥实测 CarLife（同为应用投屏）切后台正常后恢复。
 */
std::unique_ptr<carhi::ScreenEncoder> g_screenEncoder;

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

/**
 * 读一个字符串属性到定长缓冲（UTF-8）。
 * 缓冲总是以 '\0' 结尾；缺字段/类型不符时写入 fallback。
 */
void GetStringProp(napi_env env, napi_value obj, const char *key, const char *fallback,
                   char *out, size_t outSize) {
    if (out == nullptr || outSize == 0) {
        return;
    }
    const char *def = (fallback != nullptr) ? fallback : "";
    size_t defLen = std::strlen(def);
    if (defLen >= outSize) {
        defLen = outSize - 1;
    }
    std::memcpy(out, def, defLen);
    out[defLen] = '\0';

    bool has = false;
    if (napi_has_named_property(env, obj, key, &has) != napi_ok || !has) {
        return;
    }
    napi_value value = nullptr;
    if (napi_get_named_property(env, obj, key, &value) != napi_ok) {
        return;
    }
    napi_valuetype t = napi_undefined;
    if (napi_typeof(env, value, &t) != napi_ok || t != napi_string) {
        return;
    }
    size_t len = 0;
    if (napi_get_value_string_utf8(env, value, out, outSize, &len) != napi_ok) {
        out[defLen] = '\0';
    }
}

/** 取一个对象属性（不存在则返回 false，*out 置空） */
bool GetObjectProp(napi_env env, napi_value obj, const char *key, napi_value *out) {
    *out = nullptr;
    bool has = false;
    if (napi_has_named_property(env, obj, key, &has) != napi_ok || !has) {
        return false;
    }
    napi_value value = nullptr;
    if (napi_get_named_property(env, obj, key, &value) != napi_ok) {
        return false;
    }
    napi_valuetype t = napi_undefined;
    if (napi_typeof(env, value, &t) != napi_ok || t != napi_object) {
        return false;
    }
    *out = value;
    return true;
}

/**
 * 解析 surfaceId。
 *
 * ⚠ ArkTS 的 XComponent 暴露的 surfaceId 是 **string**（可能超出 double 精度），
 *   这里用 bigint 优先、string 兜底两条路解析，避免精度丢失导致 surface 无效。
 */
bool GetSurfaceId(napi_env env, napi_value value, uint64_t *out) {
    *out = 0;
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, value, &type) != napi_ok) {
        return false;
    }

    if (type == napi_bigint) {
        uint64_t v = 0;
        bool lossless = false;
        if (napi_get_value_bigint_uint64(env, value, &v, &lossless) == napi_ok && lossless) {
            *out = v;
            return true;
        }
        return false;
    }

    if (type == napi_string) {
        char buf[64] = {0};
        size_t len = 0;
        if (napi_get_value_string_utf8(env, value, buf, sizeof(buf), &len) != napi_ok) {
            return false;
        }
        try {
            *out = std::stoull(std::string(buf, len));
            return true;
        } catch (...) {
            return false;
        }
    }

    if (type == napi_number) {
        double d = 0;
        if (napi_get_value_double(env, value, &d) != napi_ok) {
            return false;
        }
        *out = static_cast<uint64_t>(d);
        return true;
    }

    return false;
}

// ---------------------------------------------------------------------------
// 导出接口
// ---------------------------------------------------------------------------

napi_value StartEncoder(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 3) {
        napi_throw_type_error(env, nullptr,
                              "startEncoder requires (surfaceId, options, onFrame, onError?)");
        return nullptr;
    }

    uint64_t surfaceId = 0;
    GetSurfaceId(env, args[0], &surfaceId);

    std::lock_guard<std::mutex> guard(g_lock);
    if (g_encoder != nullptr && g_encoder->IsRunning()) {
        LOGI("already running");
        napi_value zero = nullptr;
        napi_create_int32(env, 0, &zero);
        return zero;
    }

    carhi::EncoderParams params{};
    GetIntProp(env, args[1], "width", params.width, &params.width);
    GetIntProp(env, args[1], "height", params.height, &params.height);
    GetIntProp(env, args[1], "frameRate", params.frameRate, &params.frameRate);
    GetIntProp(env, args[1], "bitrate", params.bitrate, &params.bitrate);
    GetIntProp(env, args[1], "iFrameIntervalMs", params.iFrameIntervalMs, &params.iFrameIntervalMs);

    // 尺寸合法性检查。路线 A 下尺寸由我们自己定，1280×720 是通用兜底。
    if (params.width < 128 || params.height < 128) {
        params.width = 1280;
        params.height = 720;
    }
    if (params.frameRate < 1 || params.frameRate > 120) {
        params.frameRate = 30;
    }
    if (params.bitrate < 100000) {
        params.bitrate = 4000000;
    }

    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "CarLifeFrame", NAPI_AUTO_LENGTH, &resourceName);

    napi_status status = napi_create_threadsafe_function(
        env, args[2], nullptr, resourceName, kFrameQueueSize, 1, nullptr, nullptr, nullptr,
        CallFrameJs, &g_frameTsfn);
    if (status != napi_ok || g_frameTsfn == nullptr) {
        napi_throw_error(env, nullptr, "failed to create frame callback bridge");
        return nullptr;
    }

    // 错误回调可选
    bool hasErrorCb = false;
    napi_valuetype errorType = napi_undefined;
    if (argc >= 4 && args[3] != nullptr) {
        napi_typeof(env, args[3], &errorType);
        hasErrorCb = (errorType == napi_function);
    }
    if (hasErrorCb) {
        napi_value errName = nullptr;
        napi_create_string_utf8(env, "CarLifeError", NAPI_AUTO_LENGTH, &errName);
        napi_create_threadsafe_function(env, args[3], nullptr, errName, 8, 1, nullptr, nullptr, nullptr,
                                        CallErrorJs, &g_errorTsfn);
    }

    g_encoder = std::make_unique<carhi::CanvasEncoder>();
    int32_t stage = g_encoder->Start(surfaceId, params, OnFrame, OnError, OnLog);
    if (stage != 0) {
        LOGE("encoder start failed at stage %{public}d", stage);
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

/** 运行中补绑/换绑画布 surface（XComponent 晚于编码器就绪时用） */
napi_value AttachSurface(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    uint64_t surfaceId = 0;
    if (argc < 1 || !GetSurfaceId(env, args[0], &surfaceId)) {
        napi_value bad = nullptr;
        napi_create_int32(env, -1, &bad);
        return bad;
    }

    std::lock_guard<std::mutex> guard(g_lock);
    int32_t stage = -1;
    if (g_encoder != nullptr) {
        stage = g_encoder->AttachSurface(surfaceId);
    }
    napi_value result = nullptr;
    napi_create_int32(env, stage, &result);
    return result;
}

napi_value StopEncoder(napi_env env, napi_callback_info info) {
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

/** 运行中动态调整编码帧率（车机 98316）。返回 0 成功；非 0 失败。 */
napi_value SetFrameRate(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t frameRate = 0;
    if (argc < 1 || napi_get_value_int32(env, args[0], &frameRate) != napi_ok) {
        napi_value bad = nullptr;
        napi_create_int32(env, -1, &bad);
        return bad;
    }

    std::lock_guard<std::mutex> guard(g_lock);
    int32_t ret = -1;
    if (g_encoder != nullptr) {
        ret = g_encoder->SetFrameRate(frameRate);
    }
    napi_value result = nullptr;
    napi_create_int32(env, ret, &result);
    return result;
}

/**
 * 前台推流：把一帧 RGBA 像素画进编码器输入 surface。
 *
 * 参数：pushFrame(rgba: ArrayBuffer, width: number, height: number): number
 * 返回：0 成功；负数失败
 *   -1 编码器未运行 / -2 参数坏 / -3 EGL 初始化失败 / -4 eglSwapBuffers 失败
 *
 * ★ 为什么改成传 ArrayBuffer 而不是传 PixelMap 对象：
 *   ArkTS 侧的 image.PixelMap 是 JS 包装对象，napi_unwrap 拿到的指针
 *   布局跟 native 的 OH_PixelmapNative 不是一回事 —— 实测 GetWidth 取回 0
 *   （2026-10-14）。改为在 ArkTS 侧用 readPixelsToBufferSync 读成
 *   ArrayBuffer 再传进来，稳定且可控。代价是一次像素拷贝（1280×720
 *   RGBA 约 3.5MB），但比「完全拿不到数据」强得多。
 */
static napi_value PushFrame(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    napi_value result = nullptr;
    std::lock_guard<std::mutex> guard(g_lock);

    if (g_encoder == nullptr || !g_encoder->IsRunning()) {
        napi_create_int32(env, -1, &result);
        return result;
    }
    if (argc < 3) {
        napi_create_int32(env, -2, &result);
        return result;
    }

    void *data = nullptr;
    size_t len = 0;
    if (napi_get_arraybuffer_info(env, args[0], &data, &len) != napi_ok || data == nullptr) {
        napi_create_int32(env, -2, &result);
        return result;
    }
    int32_t w = 0, h = 0;
    napi_get_value_int32(env, args[1], &w);
    napi_get_value_int32(env, args[2], &h);
    if (w <= 0 || h <= 0 || len < static_cast<size_t>(w) * h * 4) {
        LOGI("pushFrame: 参数坏 w=%d h=%d len=%zu 期望%zu", w, h, len,
             static_cast<size_t>(w) * h * 4);
        napi_create_int32(env, -2, &result);
        return result;
    }

    int32_t ret = g_encoder->PushPixels(w, h, static_cast<const uint8_t *>(data));
    napi_create_int32(env, ret, &result);
    return result;
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

// ---------------------------------------------------------------------------
// ★ 应用投屏（录屏采集）—— OH_AVScreenCapture 路线
//
// 与自绘的区别：画面不是我们画的，而是**系统采集屏幕/指定应用窗口**得来的。
// 这条路能录到**手机上的其它 App**（如高德地图），是实现「复用高德导航画面」
// 的关键 —— 官方 CarLife 走的也是同一机制（安卓侧是 MediaProjection）。
//
// 与 `g_encoder`（自绘用）**互斥**：两者都占用编码器，上层须保证只跑一个。
// ---------------------------------------------------------------------------

/**
 * 启动应用投屏采集。
 *
 * 签名：startCapture(options, onFrame, onError?) -> number（0 成功）
 *   options：{ width, height, frameRate, bitrate, iFrameIntervalMs }
 *   onFrame：(data: ArrayBuffer, pts: number, keyFrame: boolean) => void
 */
napi_value StartCapture(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 2) {
        napi_throw_type_error(env, nullptr, "startCapture requires (options, onFrame, onError?)");
        return nullptr;
    }

    std::lock_guard<std::mutex> guard(g_lock);
    if (g_screenEncoder != nullptr && g_screenEncoder->IsRunning()) {
        LOGI("screen capture already running");
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

    g_screenEncoder = std::make_unique<carhi::ScreenEncoder>();
    int32_t stage = g_screenEncoder->Start(params, OnFrame, OnError, OnLog);
    if (stage != 0) {
        LOGE("screen capture start failed at stage %{public}d", stage);
        g_screenEncoder.reset();
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

    if (g_screenEncoder != nullptr) {
        g_screenEncoder->Stop();
        g_screenEncoder.reset();
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

/** 重启采集（抖动/中断后的恢复，内部有冷却） */
napi_value RestartCapture(napi_env env, napi_callback_info info) {
    (void)info;
    int32_t ret = -1;
    {
        std::lock_guard<std::mutex> guard(g_lock);
        if (g_screenEncoder != nullptr) {
            ret = g_screenEncoder->RestartCapture();
        }
    }
    napi_value result = nullptr;
    napi_create_int32(env, ret, &result);
    return result;
}

/** 录屏管线是否在跑 */
napi_value IsCaptureRunning(napi_env env, napi_callback_info info) {
    (void)info;
    bool running = false;
    {
        std::lock_guard<std::mutex> guard(g_lock);
        running = (g_screenEncoder != nullptr) && g_screenEncoder->IsRunning();
    }
    napi_value result = nullptr;
    napi_get_boolean(env, running, &result);
    return result;
}

/** 该错误码是否属于「可恢复」（上层可决定要不要 RestartCapture） */
napi_value IsRecoverable(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t code = 0;
    if (argc >= 1) {
        napi_get_value_int32(env, args[0], &code);
    }
    bool ok = carhi::ScreenEncoder::IsRecoverable(code);
    napi_value result = nullptr;
    napi_get_boolean(env, ok, &result);
    return result;
}

/** 录屏编码尺寸 */
napi_value CaptureEncodedSize(napi_env env, napi_callback_info info) {
    (void)info;
    int32_t w = 0;
    int32_t h = 0;
    {
        std::lock_guard<std::mutex> guard(g_lock);
        if (g_screenEncoder != nullptr) {
            w = g_screenEncoder->EncodedWidth();
            h = g_screenEncoder->EncodedHeight();
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

/**
 * 路线 A 机制验证：往编码器输入 surface 画 → 能否出帧。
 *
 * 为什么单独做这个：A2（XComponent surfaceId 交给编码器）已证伪，
 * A1/β 的共同地基是「能往编码器 surface 写」。先验证地基再投人力。
 *
 * 签名：runPipelineProbe(width, height, seconds) -> 结果对象
 * 注意：**同步阻塞** seconds 秒，调用方须在 UI 上提示。
 */
napi_value RunPipelineProbe(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t width = 1280;
    int32_t height = 720;
    int32_t seconds = 3;
    if (argc >= 1) { napi_get_value_int32(env, args[0], &width); }
    if (argc >= 2) { napi_get_value_int32(env, args[1], &height); }
    if (argc >= 3) { napi_get_value_int32(env, args[2], &seconds); }

    // 探针全程独占编码器：先确保没有别的实例在跑
    {
        std::lock_guard<std::mutex> guard(g_lock);
        if (g_encoder != nullptr && g_encoder->IsRunning()) {
            napi_throw_error(env, nullptr, "编码器已在运行，请先 stopEncoder 再验证");
            return nullptr;
        }
    }

    carhi::ProbeResult r = carhi::RunPipelineProbe(width, height, seconds, nullptr);

    napi_value result = nullptr;
    napi_create_object(env, &result);
    auto setInt = [&](const char *key, int64_t v) {
        napi_value val = nullptr;
        napi_create_int64(env, v, &val);
        napi_set_named_property(env, result, key, val);
    };
    auto setStr = [&](const char *key, const std::string &v) {
        napi_value val = nullptr;
        napi_create_string_utf8(env, v.c_str(), NAPI_AUTO_LENGTH, &val);
        napi_set_named_property(env, result, key, val);
    };
    auto setBool = [&](const char *key, bool v) {
        napi_value val = nullptr;
        napi_get_boolean(env, v, &val);
        napi_set_named_property(env, result, key, val);
    };

    setBool("ok", r.ok);
    setInt("encWidth", r.encWidth);
    setInt("encHeight", r.encHeight);
    setInt("surfaceIdOk", r.surfaceIdOk);
    setStr("surfaceId", std::to_string(r.surfaceId));
    setInt("eglOk", r.eglOk);
    setInt("eglSurfaceOk", r.eglSurfaceOk);
    setInt("swapCount", r.swapCount);
    setInt("outputFrames", r.outputFrames);
    setInt("firstOutputPts", r.firstOutputPts);
    setStr("stage", r.stage);
    setStr("error", r.error);
    return result;
}

// ---------------------------------------------------------------------------
// 路线 A1：原生自绘 HMI
//
// 与 startEncoder 的关键区别：**不需要外部 surfaceId**。
// 编码器（消费者）自己持有输入 surface，HmiRenderer（生产者）直接往上面画。
// 这条通路的画面来源是**我们自己的渲染线程**，与屏幕显示状态无关 ——
// 所以切后台、息屏都不会停，这正是"后台推流"的根据。
// ---------------------------------------------------------------------------

/** 释放 HMI + 编码器 + 两个 threadsafe function（调用方须持有 g_lock） */
void TeardownHmiLocked() {
    if (g_hmi != nullptr) {
        g_hmi->Stop();
        g_hmi.reset();
    }
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
}

/**
 * 启动「编码器 + 原生自绘 HMI」。
 *
 * 签名：startHmi(options, onFrame, onError?) -> stage
 *   stage: 0 成功
 *          1..7 编码器失败（同 StartStage）
 *          8    拿不到编码器输入 window
 *          9    HmiRenderer 起不来（GPU 表面与 CPU 位图后端都不可用）
 */
napi_value StartHmi(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    napi_value ok = nullptr;
    napi_create_int32(env, 0, &ok);
    if (argc < 2) {
        napi_throw_type_error(env, nullptr, "startHmi requires (options, onFrame, onError?)");
        return nullptr;
    }

    std::lock_guard<std::mutex> guard(g_lock);
    if (g_hmi != nullptr && g_hmi->IsRunning()) {
        LOGI("HMI already running");
        return ok;
    }
    // 若上一次没清干净（异常路径），先收拾
    TeardownHmiLocked();

    carhi::EncoderParams params{};
    GetIntProp(env, args[1], "width", params.width, &params.width);
    GetIntProp(env, args[1], "height", params.height, &params.height);
    GetIntProp(env, args[1], "frameRate", params.frameRate, &params.frameRate);
    GetIntProp(env, args[1], "bitrate", params.bitrate, &params.bitrate);
    GetIntProp(env, args[1], "iFrameIntervalMs", params.iFrameIntervalMs, &params.iFrameIntervalMs);
    if (params.width < 128 || params.height < 128) {
        params.width = 1280;
        params.height = 720;
    }
    if (params.frameRate < 1 || params.frameRate > 120) {
        params.frameRate = 30;
    }
    if (params.bitrate < 100000) {
        params.bitrate = 4000000;
    }
    // 编码器要求偶数尺寸
    params.width -= params.width % 2;
    params.height -= params.height % 2;

    // ---- 1. 帧回调桥（与 startEncoder 同一套）----
    // ★ 真机踩坑（2026-10-15）：签名是 startHmi(options, onFrame, onError?)，
    //   args[1]=onFrame、args[2]=onError。这里曾错绑成 args[2]，
    //   导致**每一帧 H.264 都走进错误回调**（表现：[画面] 错误([object ArrayBuffer]): 0
    //   —— 即 CallFrameJs 的 (ArrayBuffer, pts=0) 两个参数），ArkTS 误判为致命错误
    //   → stopStreaming() → 车机一帧都收不到。必须绑 args[1]。
    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "CarLifeFrame", NAPI_AUTO_LENGTH, &resourceName);
    if (napi_create_threadsafe_function(env, args[1], nullptr, resourceName, kFrameQueueSize, 1,
                                        nullptr, nullptr, nullptr, CallFrameJs,
                                        &g_frameTsfn) != napi_ok || g_frameTsfn == nullptr) {
        napi_throw_error(env, nullptr, "failed to create frame callback bridge");
        return nullptr;
    }
    bool hasErrorCb = false;
    napi_valuetype errorType = napi_undefined;
    if (argc >= 3 && args[2] != nullptr) {
        napi_typeof(env, args[2], &errorType);
        hasErrorCb = (errorType == napi_function);
    }
    if (hasErrorCb) {
        napi_value errName = nullptr;
        napi_create_string_utf8(env, "CarLifeError", NAPI_AUTO_LENGTH, &errName);
        napi_create_threadsafe_function(env, args[2], nullptr, errName, 8, 1, nullptr, nullptr,
                                        nullptr, CallErrorJs, &g_errorTsfn);
    }

    // ---- 2. 编码器（surfaceId=0：不要外部画布，surface 归它自己）----
    g_encoder = std::make_unique<carhi::CanvasEncoder>();
    int32_t stage = g_encoder->Start(0, params, OnFrame, OnError, OnLog);
    if (stage != 0) {
        LOGE("startHmi: 编码器启动失败 stage=%{public}d", stage);
        TeardownHmiLocked();
        napi_value fail = nullptr;
        napi_create_int32(env, stage, &fail);
        return fail;
    }

    OHNativeWindow *win = nullptr;
    if (!g_encoder->GetInputWindow(&win) || win == nullptr) {
        LOGE("startHmi: 拿不到编码器输入 window");
        TeardownHmiLocked();
        napi_value fail = nullptr;
        napi_create_int32(env, 8, &fail);
        return fail;
    }

    // ---- 3. 自绘渲染器 ----
    g_hmi = std::make_unique<carhi::HmiRenderer>();
    carhi::CanvasEncoder *enc = g_encoder.get();
    // CPU 兜底后端时，像素走**已验证过**的 GL 上传通路进编码器
    g_hmi->SetCpuPresenter([enc](int32_t w, int32_t h, const uint8_t *rgba) -> int32_t {
        return enc->PushPixels(w, h, rgba);
    });
    // 自愈判据：渲染器拿编码器的**实际出帧数**来判"像素到底有没有进编码器"
    g_hmi->SetOutputFramesProbe([enc]() -> uint64_t { return enc->OutputFrameCount(); });
    // 切到 GPU 后端前，先把编码器 window 上可能存在的 EGLSurface 解绑
    // （CPU 后端建的，会和 GPU 表面抢同一个 window）
    g_hmi->SetGlReleaser([enc]() { enc->ReleaseGlResources(); });
    int32_t ret = g_hmi->Start(win, params.width, params.height, params.frameRate,
                               [](const std::string &m) { LOGI("%{public}s", m.c_str()); });
    if (ret != 0) {
        LOGE("startHmi: HmiRenderer 启动失败 ret=%{public}d", ret);
        TeardownHmiLocked();
        napi_value fail = nullptr;
        napi_create_int32(env, 9, &fail);
        return fail;
    }

    LOGI("startHmi: 已启动 %{public}dx%{public}d@%{public}d bitrate=%{public}d",
         params.width, params.height, params.frameRate, params.bitrate);
    return ok;
}

/**
 * 推送 HMI 状态。
 *
 * 签名：setHmiState(state) -> void
 * state = {
 *   page: 0|1,
 *   connected: 0|1,
 *   navi:  { turnType, distanceText, distanceUnit, road, hint, nextHint },
 *   audio: { title, artist, positionMs, durationMs, playing },
 * }
 * 未提供的字段保持默认值。
 */
napi_value SetHmiState(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    if (argc < 1 || args[0] == nullptr) {
        return undefined;
    }
    napi_valuetype t = napi_undefined;
    if (napi_typeof(env, args[0], &t) != napi_ok || t != napi_object) {
        return undefined;
    }

    carhi::HmiState st{};
    GetIntProp(env, args[0], "page", st.page, &st.page);
    GetIntProp(env, args[0], "connected", st.connected, &st.connected);

    napi_value navi = nullptr;
    if (GetObjectProp(env, args[0], "navi", &navi)) {
        GetIntProp(env, navi, "turnType", st.navi.turnType, &st.navi.turnType);
        GetIntProp(env, navi, "distanceM", st.navi.distanceM, &st.navi.distanceM);
        GetIntProp(env, navi, "progress", st.navi.progress, &st.navi.progress);
        GetStringProp(env, navi, "distanceText", st.navi.distanceText, st.navi.distanceText,
                      sizeof(st.navi.distanceText));
        GetStringProp(env, navi, "distanceUnit", st.navi.distanceUnit, st.navi.distanceUnit,
                      sizeof(st.navi.distanceUnit));
        GetStringProp(env, navi, "road", st.navi.road, st.navi.road, sizeof(st.navi.road));
        GetStringProp(env, navi, "hint", st.navi.hint, st.navi.hint, sizeof(st.navi.hint));
        GetStringProp(env, navi, "nextHint", st.navi.nextHint, st.navi.nextHint,
                      sizeof(st.navi.nextHint));
    }

    napi_value audio = nullptr;
    if (GetObjectProp(env, args[0], "audio", &audio)) {
        GetStringProp(env, audio, "title", st.audio.title, st.audio.title, sizeof(st.audio.title));
        GetStringProp(env, audio, "artist", st.audio.artist, st.audio.artist,
                      sizeof(st.audio.artist));
        GetIntProp(env, audio, "positionMs", st.audio.positionMs, &st.audio.positionMs);
        GetIntProp(env, audio, "durationMs", st.audio.durationMs, &st.audio.durationMs);
        GetIntProp(env, audio, "playing", st.audio.playing, &st.audio.playing);
    }

    // ---- 首页：顶部状态栏 ----
    napi_value status = nullptr;
    if (GetObjectProp(env, args[0], "status", &status)) {
        GetStringProp(env, status, "clock", st.status.clock, st.status.clock,
                      sizeof(st.status.clock));
        GetStringProp(env, status, "carrier", st.status.carrier, st.status.carrier,
                      sizeof(st.status.carrier));
        GetIntProp(env, status, "signalBars", st.status.signalBars, &st.status.signalBars);
        GetIntProp(env, status, "batteryPct", st.status.batteryPct, &st.status.batteryPct);
    }

    // ---- 首页：天气卡 ----
    napi_value weather = nullptr;
    if (GetObjectProp(env, args[0], "weather", &weather)) {
        GetStringProp(env, weather, "condition", st.weather.condition, st.weather.condition,
                      sizeof(st.weather.condition));
        GetStringProp(env, weather, "city", st.weather.city, st.weather.city,
                      sizeof(st.weather.city));
        GetStringProp(env, weather, "airQuality", st.weather.airQuality, st.weather.airQuality,
                      sizeof(st.weather.airQuality));
        GetIntProp(env, weather, "tempC", st.weather.tempC, &st.weather.tempC);
    }

    // ---- 首页：通勤/到达卡 ----
    napi_value eta = nullptr;
    if (GetObjectProp(env, args[0], "eta", &eta)) {
        GetStringProp(env, eta, "arriveAt", st.eta.arriveAt, st.eta.arriveAt,
                      sizeof(st.eta.arriveAt));
        GetIntProp(env, eta, "minutes", st.eta.minutes, &st.eta.minutes);
    }

    std::lock_guard<std::mutex> guard(g_lock);
    if (g_hmi != nullptr) {
        g_hmi->SetState(st);
    }
    return undefined;
}

napi_value StopHmi(napi_env env, napi_callback_info info) {
    (void) info;
    std::lock_guard<std::mutex> guard(g_lock);
    TeardownHmiLocked();
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

/**
 * 手动切换渲染后端。
 *
 * 签名：setHmiBackend(backend) -> void
 *   backend: 0 = AUTO（默认，GPU 优先 + 自愈）
 *            1 = 强制 GPU OnScreen
 *            2 = 强制 CPU 位图 → GL 上传
 *
 * 用途：万一 GPU 后端在真机上画不出东西（黑屏），用户在设置页一键切 CPU
 * 就能看到画面，不必等我改代码重编。
 */
napi_value SetHmiBackend(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    if (argc < 1 || args[0] == nullptr) {
        return undefined;
    }
    int32_t backend = 0;
    if (napi_get_value_int32(env, args[0], &backend) != napi_ok) {
        return undefined;
    }
    std::lock_guard<std::mutex> guard(g_lock);
    if (g_hmi != nullptr) {
        g_hmi->RequestBackend(backend);
    } else {
        LOGI("setHmiBackend: HMI 未运行，忽略 backend=%{public}d", backend);
    }
    return undefined;
}

/**
 * 离线自绘自检（不需要编码器、不需要车机、不需要 window）。
 *
 * 签名：
 *   runHmiSelfCheck({ width, height }) -> {
 *     ok, failCode, cpuBackendOk,
 *     width, height,
 *     homeMs, navMs,
 *     home: ArrayBuffer | null,   // RGBA8888，长度 = width*height*4
 *     nav:  ArrayBuffer | null,
 *   }
 *
 * 为什么要它：整条「自绘 → 编码器 → 推流」的运行时验证被编码器卡住 ——
 * 有些环境（典型是模拟器）**根本没有视频编码器**（AVC/HEVC 全不可用），
 * 于是「画得出来吗」这个问题根本问不出去。但绘图只依赖 Skia 的 CPU 位图
 * 后端，跟编码器完全无关，而且是同步的 —— 可以独立验。
 *
 * 像素不在这里编码成 PNG：`native_drawing` 里没有图像编码接口。
 * 裸 RGBA 交回 ArkTS，由 image kit 落盘。
 *
 * ⚠ 用一个**独立的** HmiRenderer 实例，绝不碰 g_hmi —— 直接复用会把
 *   HMI 的运行状态搅乱。
 */
napi_value RunHmiSelfCheck(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t width = 1280;
    int32_t height = 720;
    if (argc >= 1 && args[0] != nullptr) {
        napi_value v = nullptr;
        if (napi_get_named_property(env, args[0], "width", &v) == napi_ok && v != nullptr) {
            napi_get_value_int32(env, v, &width);
        }
        v = nullptr;
        if (napi_get_named_property(env, args[0], "height", &v) == napi_ok && v != nullptr) {
            napi_get_value_int32(env, v, &height);
        }
    }
    if (width < 64) { width = 1280; }
    if (height < 64) { height = 720; }

    // 每页的像素拷一份存下来（回调里的指针在自检返回后就失效了）
    struct PageOut {
        std::vector<uint8_t> bytes;
        int32_t width = 0;
        int32_t height = 0;
        bool got = false;
    };
    PageOut pages[2];   // 0 = home, 1 = nav

    carhi::HmiRenderer probe;
    carhi::HmiRenderer::SelfCheckResult r = probe.RunSelfCheck(
        width, height,
        [&pages](const char *name, const uint8_t *px, int32_t w, int32_t h, double) {
            int idx = -1;
            if (name != nullptr && strcmp(name, "home") == 0) { idx = 0; }
            else if (name != nullptr && strcmp(name, "nav") == 0) { idx = 1; }
            if (idx < 0 || px == nullptr || w <= 0 || h <= 0) { return; }
            size_t n = static_cast<size_t>(w) * h * 4;
            pages[idx].bytes.assign(px, px + n);
            pages[idx].width = w;
            pages[idx].height = h;
            pages[idx].got = true;
        });

    const bool ok = (r.failCode == 0);

    napi_value result = nullptr;
    napi_create_object(env, &result);
    napi_value v = nullptr;

    napi_get_boolean(env, ok, &v);
    napi_set_named_property(env, result, "ok", v);
    napi_create_int32(env, r.failCode, &v);
    napi_set_named_property(env, result, "failCode", v);
    napi_create_int32(env, r.cpuBackendOk, &v);
    napi_set_named_property(env, result, "cpuBackendOk", v);
    napi_create_int32(env, r.width, &v);
    napi_set_named_property(env, result, "width", v);
    napi_create_int32(env, r.height, &v);
    napi_set_named_property(env, result, "height", v);
    napi_create_double(env, r.homeMs, &v);
    napi_set_named_property(env, result, "homeMs", v);
    napi_create_double(env, r.navMs, &v);
    napi_set_named_property(env, result, "navMs", v);
    napi_create_int32(env, r.giveHomeCode, &v);
    napi_set_named_property(env, result, "giveHomeCode", v);
    napi_create_int32(env, r.giveNavCode, &v);
    napi_set_named_property(env, result, "giveNavCode", v);

    const char *names[2] = {"home", "nav"};
    for (int i = 0; i < 2; ++i) {
        napi_value buf = nullptr;
        if (pages[i].got && !pages[i].bytes.empty()) {
            void *data = nullptr;
            napi_create_arraybuffer(env, pages[i].bytes.size(), &data, &buf);
            if (data != nullptr) {
                memcpy(data, pages[i].bytes.data(), pages[i].bytes.size());
            }
        } else {
            napi_get_null(env, &buf);
        }
        napi_set_named_property(env, result, names[i], buf);
    }

    LOGI("runHmiSelfCheck: ok=%{public}d fail=%{public}d cpuOk=%{public}d "
         "%{public}dx%{public}d home=%{public}.1fms nav=%{public}.1fms",
         ok ? 1 : 0, r.failCode, r.cpuBackendOk, r.width, r.height,
         r.homeMs, r.navMs);
    return result;
}

/**
 * HMI 诊断数据。
 *
 * 签名：hmiStats() -> { running, cpuBackend, backend, selfHealed,
 *                       frames, outputFrames, flushCode }
 */
napi_value HmiStats(napi_env env, napi_callback_info info) {
    (void) info;
    bool running = false;
    bool cpu = false;
    bool healed = false;
    int32_t backend = -1;
    int64_t frames = 0;
    int64_t outputFrames = 0;
    int32_t flush = 0;
    {
        std::lock_guard<std::mutex> guard(g_lock);
        if (g_hmi != nullptr) {
            running = g_hmi->IsRunning();
            cpu = g_hmi->UsingCpuBackend();
            healed = g_hmi->SelfHealed();
            backend = g_hmi->CurrentBackend();
            frames = static_cast<int64_t>(g_hmi->FrameCount());
            flush = g_hmi->LastFlushCode();
        }
        if (g_encoder != nullptr) {
            outputFrames = static_cast<int64_t>(g_encoder->OutputFrameCount());
        }
    }
    napi_value result = nullptr;
    napi_create_object(env, &result);
    napi_value v = nullptr;
    napi_get_boolean(env, running, &v);
    napi_set_named_property(env, result, "running", v);
    napi_get_boolean(env, cpu, &v);
    napi_set_named_property(env, result, "cpuBackend", v);
    napi_get_boolean(env, healed, &v);
    napi_set_named_property(env, result, "selfHealed", v);
    napi_create_int32(env, backend, &v);
    napi_set_named_property(env, result, "backend", v);
    napi_create_int64(env, frames, &v);
    napi_set_named_property(env, result, "frames", v);
    napi_create_int64(env, outputFrames, &v);
    napi_set_named_property(env, result, "outputFrames", v);
    napi_create_int32(env, flush, &v);
    napi_set_named_property(env, result, "flushCode", v);
    return result;
}

} // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"startEncoder", nullptr, StartEncoder, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"attachSurface", nullptr, AttachSurface, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopEncoder", nullptr, StopEncoder, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"requestKeyFrame", nullptr, RequestKeyFrame, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setFrameRate", nullptr, SetFrameRate, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"pushFrame", nullptr, PushFrame, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isRunning", nullptr, IsRunning, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"encodedSize", nullptr, EncodedSize, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"runPipelineProbe", nullptr, RunPipelineProbe, nullptr, nullptr, nullptr, napi_default, nullptr},
        // ---- 路线 A1：原生自绘 HMI ----
        {"startHmi", nullptr, StartHmi, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setHmiState", nullptr, SetHmiState, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setHmiBackend", nullptr, SetHmiBackend, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopHmi", nullptr, StopHmi, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"hmiStats", nullptr, HmiStats, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"runHmiSelfCheck", nullptr, RunHmiSelfCheck, nullptr, nullptr, nullptr, napi_default, nullptr},

        // ★ 应用投屏（录屏采集）—— 可录到手机上的其它 App
        {"startCapture", nullptr, StartCapture, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopCapture", nullptr, StopCapture, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"restartCapture", nullptr, RestartCapture, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isCaptureRunning", nullptr, IsCaptureRunning, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isRecoverable", nullptr, IsRecoverable, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"captureEncodedSize", nullptr, CaptureEncodedSize, nullptr, nullptr, nullptr, napi_default, nullptr},
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
