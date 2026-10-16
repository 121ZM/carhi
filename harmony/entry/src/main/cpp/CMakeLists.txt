# CarLife 手机端 Native 编码模块（路线 A：自绘画面，不走录屏）
#
# 为什么这一层必须是 C++：
#   1. ArkTS 侧**没有**视频编码 API（SDK 全量检索确认，media.d.ts 无 VideoEncoder）
#   2. 需要把「自绘画布」的渲染结果直接喂给硬件编码器（零拷贝 Surface 通路）
#   所以"自绘 -> 编码 -> 拿 H.264 裸流"只能在 Native 层完成。
#
# ★ 2026-10-13 查证后修正：
#   「XComponent surfaceId 交给编码器」的 A2 路数**不成立**（编码器与
#   XComponent 各持一个 surface，无 API 连通）。真实机制是「生产者往
#   编码器自己的输入 surface 里写」。为此新增 pipeline_probe.cpp 做最小验证，
#   并链接 EGL/GLES 用于直接画进编码器 surface。

cmake_minimum_required(VERSION 3.5.0)
project(carlifecodec)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

include_directories(${NATIVERENDER_ROOT_PATH})

add_library(carlifecodec SHARED
    napi_init.cpp
    canvas_encoder.cpp
    hmi_renderer.cpp
    pipeline_probe.cpp
    screen_encoder.cpp
)

target_link_libraries(carlifecodec PUBLIC
    libace_napi.z.so                  # NAPI
    libhilog_ndk.z.so                 # 日志
    libnative_media_core.so           # OH_AVBuffer / OH_AVFormat
    libnative_media_codecbase.so      # OH_AVCodec 基类 / OH_MD_KEY_*
    libnative_media_venc.so           # OH_VideoEncoder_*
    libnative_avscreen_capture.so     # ★ OH_AVScreenCapture_*（应用投屏采集）
    libnative_window.so               # OHNativeWindow (Surface)
    libpixelmap.so                    # OH_PixelmapNative_*（前台截图送编码器）
    libEGL.so                         # EGL（自绘 Surface 通路 / CPU 兜底上传）
    libGLESv3.so                      # OpenGL ES 3.x
    libnative_drawing.so              # ★ OH_Drawing_*（Skia 2D：文字排版/圆角/路径）
)
