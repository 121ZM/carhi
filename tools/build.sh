#!/usr/bin/env bash
# CarLife 手机端（HarmonyOS）命令行构建脚本
#
# 依赖：Command Line Tools（含 hvigor / ohpm / SDK / native 工具链）+ 一个 JDK(11+)
# 打包步骤会 `spawn java`，所以 JAVA_HOME 必须配好，否则报 00308018 Unknown Error。
#
# 用法：
#   bash tools/build.sh            # 增量构建（不签名）
#   bash tools/build.sh clean      # 清空产物后从零构建
#   bash tools/build.sh release    # release 模式
#   bash tools/build.sh signed     # 构建后追加签名（签名材料见 certs/README.md）
#   bash tools/build.sh clean signed release   # 参数可叠加
#
# 若工具链不在默认位置，用环境变量覆盖：
#   CLT_HOME=E:/AITools/command-line-tools JAVA_HOME=/path/to/jdk bash tools/build.sh

set -euo pipefail

# ---------------- 路径配置 ----------------
# 优先用环境变量 CLT_HOME 指定的 Command Line Tools / DevEco Studio 安装目录。
# 未指定时按序探测本机已知位置（DevEco Studio 已内置 hvigor / node / SDK）。
if [ -z "${CLT_HOME:-}" ]; then
  for candidate in \
      "/d/dev/Huawei/DevEco Studio" \
      "D:/dev/Huawei/DevEco Studio" \
      "/d/dev/DevEco Studio" \
      "D:/dev/DevEco Studio" \
      "E:/AITools/command-line-tools" ; do
    if [ -f "$candidate/tools/hvigor/bin/hvigorw.js" ] || [ -f "$candidate/hvigor/bin/hvigorw.js" ]; then
      CLT_HOME="$candidate"
      break
    fi
  done
fi
CLT_HOME="${CLT_HOME:-E:/AITools/command-line-tools}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../harmony" && pwd)"

# JDK：未显式指定时，依次尝试 DevEco 自带 jbr 与本机常见 JDK 位置
if [ -z "${JAVA_HOME:-}" ]; then
  for candidate in \
      "$CLT_HOME/jbr" \
      "C:/Users/dev/.jdks/jbr_dcevm-11.0.16" \
      "C:/Program Files/Java/jdk-17" \
      "C:/Program Files/Java/jdk-11" ; do
    if [ -x "$candidate/bin/java.exe" ] || [ -x "$candidate/bin/java" ]; then
      JAVA_HOME="$candidate"
      break
    fi
  done
fi
if [ -z "${JAVA_HOME:-}" ]; then
  echo "ERROR: 找不到 JDK。请设置 JAVA_HOME（打包步骤需要 java）。" >&2
  exit 1
fi

# ---------------- 环境变量 ----------------
# DevEco Studio 布局：SDK 在 <root>/sdk，node 在 <root>/tools/node，
# hvigor 在 <root>/tools/hvigor；Command Line Tools 布局则少一层 tools/。
if [ -d "$CLT_HOME/tools/node" ]; then
  DEVECO_NODE_HOME="$CLT_HOME/tools/node"
  HVIGORW_JS="$CLT_HOME/tools/hvigor/bin/hvigorw.js"
else
  DEVECO_NODE_HOME="$CLT_HOME/tool/node"
  HVIGORW_JS="$CLT_HOME/hvigor/bin/hvigorw.js"
fi

if [ -d "$CLT_HOME/sdk" ]; then
  export DEVECO_SDK_HOME="$CLT_HOME/sdk"
fi
export DEVECO_NODE_HOME
export NODE_HOME="$DEVECO_NODE_HOME"
export JAVA_HOME

# PATH 里必须放 Unix 风格路径：Git Bash 会在 spawn Windows 进程时做路径转换，
# 直接放 "C:/..." 形式会导致 hvigor 打包阶段 spawn java 失败（ENOENT）。
if command -v cygpath >/dev/null 2>&1; then
  JAVA_BIN="$(cygpath -u "$JAVA_HOME")/bin"
else
  JAVA_BIN="$JAVA_HOME/bin"
fi
export PATH="$JAVA_BIN:$PATH"

NODE_EXE="$DEVECO_NODE_HOME/node.exe"
[ -x "$NODE_EXE" ] || NODE_EXE="$DEVECO_NODE_HOME/node"

if [ ! -f "$HVIGORW_JS" ]; then
  echo "ERROR: 找不到 hvigor 入口: $HVIGORW_JS" >&2
  echo "       请用 CLT_HOME 指定 DevEco Studio / Command Line Tools 根目录。" >&2
  exit 1
fi

# ---------------- 参数 ----------------
MODE="debug"
TASK="assembleHap"
DO_CLEAN=0
DO_SIGN=0
for arg in "$@"; do
  case "$arg" in
    clean)   DO_CLEAN=1 ;;
    release) MODE="release" ;;
    debug)   MODE="debug" ;;
    signed)  DO_SIGN=1 ;;
    *)       echo "未知参数: $arg" >&2; exit 2 ;;
  esac
done

cd "$PROJECT_DIR"

if [ "$DO_CLEAN" = "1" ]; then
  echo "==> 清空构建产物"
  rm -rf entry/build entry/.cxx build .hvigor
fi

echo "==> 工具链: $CLT_HOME"
echo "==> JDK   : $JAVA_HOME"
echo "==> 工程  : $PROJECT_DIR"
echo "==> 模式  : $MODE"
echo

# --no-daemon：CI/脚本场景下避免常驻进程，退出更干净
"$NODE_EXE" "$HVIGORW_JS" "$TASK" \
    --mode module -p product=default -p buildMode="$MODE" \
    --no-daemon

echo
echo "==> 产物:"
find "$PROJECT_DIR/entry/build" -name "*.hap" -print 2>/dev/null || echo "（未找到 hap）"

# ---------------- 可选：签名 ----------------
if [ "$DO_SIGN" = "1" ]; then
  echo
  echo "==> 追加签名（模式 $MODE）"
  bash "$(dirname "${BASH_SOURCE[0]}")/sign.sh" sign "$MODE"
fi
