/*
 * 编码管线最小验证探针（路线 A · 机制查证用）
 *
 * ## 为什么需要它
 *
 * 路线 A 的 A2 方案（把 XComponent 的 surfaceId 交给编码器）经查证在鸿蒙上
 * **机制不成立**：编码器与 XComponent 各持一个 surface，中间没有任何 API
 * 能把两者连通，所以编码器永远收不到输入帧（实测 routeA5：编码器起来了
 * 但 encoder output 一条都没有）。
 *
 * 本探针用于验证**唯一成立的机制**：
 *   生产者（我们自己的 GL）→ 往【编码器自己的输入 surface】里画 → 编码器出帧
 *
 * 这正是 A1（EGL 手绘）与 β（ArkUI 渲染后拷贝）两条路共同的地基。
 * 地基通了，才值得投入做上层界面；地基不通，两条路都得推翻。
 *
 * ## 验证内容
 *
 *   1. 建编码器，拿它自己的输入 surface（OH_VideoEncoder_GetSurface）
 *   2. 取该 surface 的 surfaceId（OH_NativeWindow_GetSurfaceId）
 *   3. 在 native EGL display 上，用该 id 建 EGLSurface
 *   4. 每帧 glClearColor（颜色循环）+ eglSwapBuffers
 *   5. 统计编码器实际输出帧数
 *
 * 全程**不启动任何网络/协议**，与 CarLife 握手无关，可独立跑。
 */

#ifndef CARHI_PIPELINE_PROBE_H
#define CARHI_PIPELINE_PROBE_H

#include <cstdint>
#include <functional>
#include <string>

namespace carhi {

/** 探针结果（回传到 ArkTS 展示） */
struct ProbeResult {
    bool ok = false;             // 是否跑通（有帧产出）
    int32_t encWidth = 0;        // 编码器实际宽
    int32_t encHeight = 0;       // 编码器实际高
    int32_t surfaceIdOk = 0;     // 是否成功取到编码器 surface 的 id（0/1）
    uint64_t surfaceId = 0;      // 编码器 surface 的 id
    int32_t eglOk = 0;           // EGL 初始化是否成功（0/1）
    int32_t eglSurfaceOk = 0;    // EGLSurface 创建是否成功（0/1）
    int32_t swapCount = 0;       // 实际 eglSwapBuffers 次数（≈喂进去的帧数）
    int32_t outputFrames = 0;    // 编码器实际吐出的帧数
    int64_t firstOutputPts = -1; // 第一帧输出的 pts
    std::string stage;           // 人类可读的阶段说明（最后走到了哪）
    std::string error;           // 失败原因
};

/**
 * 跑一次最小验证。
 *
 * @param width   编码宽（必须偶数）
 * @param height  编码高（必须偶数）
 * @param seconds 持续秒数（建议 2~3）
 * @param log     日志回调（同 hilog + 回传 ArkTS）
 */
ProbeResult RunPipelineProbe(int32_t width, int32_t height, int32_t seconds,
                             const std::function<void(const std::string &)> &log);

} // namespace carhi

#endif // CARHI_PIPELINE_PROBE_H
