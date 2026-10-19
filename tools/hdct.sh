#!/bin/bash
# hdc 真机包装器：每条命令前先重连，避免 "need connect-key"
DEV="${HDC_DEV:-192.168.0.186:39713}"
HDC="E:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe"
"$HDC" tconn "$DEV" >/dev/null 2>&1
"$HDC" -t "$DEV" "$@"
