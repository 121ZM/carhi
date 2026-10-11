# CarLife 手机端 Native 采集编码模块
#
# 为什么这一层必须是 C++：
#   1. ArkTS 侧**没有**视频编码 API（SDK 全量检索确认，media.d.ts 无 VideoEncoder）
#   2. ArkTS 的 AVScreenCaptureRecorder 只能录到文件（config.fd 必填），拿不到实时帧
#   所以"采集 -> 编码 -> 拿 H.264 裸流"只能在 Native 层完成。

cmake_minimum_required(VERSION 3.5.0)
project(carlifecodec)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

include_directories(${NATIVERENDER_ROOT_PATH})

add_library(carlifecodec SHARED
    napi_init.cpp
    screen_encoder.cpp
)

target_link_libraries(carlifecodec PUBLIC
    libace_napi.z.so                  # NAPI
    libhilog_ndk.z.so                 # 日志
    libnative_media_core.so           # OH_AVBuffer / OH_AVFormat
    libnative_media_codecbase.so      # OH_AVCodec 基类 / OH_MD_KEY_*
    libnative_media_venc.so           # OH_VideoEncoder_*
    libnative_avscreen_capture.so     # OH_AVScreenCapture_*
    libnative_window.so               # OHNativeWindow (Surface)
)
