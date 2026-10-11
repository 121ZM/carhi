#!/usr/bin/env bash
# 切换 App 的 bundleName。
#
# 背景：签名用的 Profile 里写死了 bundle-name，而且它由华为签名，改不了。
# 所以「复用某个旧 Profile」的唯一办法，是把 App 的 bundleName 改成与它一致。
#
# 用法：
#   bash tools/bundle.sh                 # 查看当前 bundleName
#   bash tools/bundle.sh <bundleName>    # 改成指定包名
#   bash tools/bundle.sh reset           # 恢复默认 com.carhi.carlifephone
#
# 注意：改成与其它已安装应用相同的 bundleName、且用同一张证书签名时，
#       系统会判定为对该应用的「升级」并覆盖它。仅建议临时调试用。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_JSON="$ROOT/harmony/AppScope/app.json5"
DEFAULT_BUNDLE="com.carhi.carlifephone"

[ -f "$APP_JSON" ] || { echo "ERROR: 找不到 $APP_JSON" >&2; exit 1; }

# Python 在 Windows 上不认 /e/... 这种路径，转成盘符路径
if command -v cygpath >/dev/null 2>&1; then
  WIN_JSON="$(cygpath -w "$APP_JSON")"
else
  WIN_JSON="$APP_JSON"
fi

_read() {
  python - "$WIN_JSON" <<'PY'
import re, sys
s = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r'"bundleName"\s*:\s*"([^"]+)"', s)
print(m.group(1) if m else '(未找到)')
PY
}

_write() {
  python - "$WIN_JSON" "$1" <<'PY'
import re, sys
p, name = sys.argv[1], sys.argv[2]
s = open(p, encoding='utf-8').read()
s2, n = re.subn(r'("bundleName"\s*:\s*")[^"]+(")',
                lambda m: m.group(1) + name + m.group(2), s)
open(p, 'w', encoding='utf-8', newline='').write(s2)
print(f'  已写入 {name}（替换 {n} 处）')
PY
}

case "${1:-show}" in
  show|"")
    echo "==> 当前 bundleName: $(_read)"
    echo "==> 默认 bundleName: $DEFAULT_BUNDLE"
    ;;

  reset)
    echo "==> 恢复默认包名"
    _write "$DEFAULT_BUNDLE"
    echo
    echo "改完需重新构建： bash tools/build.sh"
    ;;

  -h|--help|help)
    sed -n '2,/^$/p' "$0"
    ;;

  *)
    NEW="$1"
    echo "==> 切换 bundleName"
    echo "  改前: $(_read)"
    _write "$NEW"
    echo "  改后: $(_read)"
    if [ "$NEW" != "$DEFAULT_BUNDLE" ]; then
      echo
      echo "  [!] 当前不是默认包名。若用与旧 Profile 相同的证书签名，"
      echo "      安装时系统会视为对该包名应用的『升级』，可能覆盖它。"
      echo "      调试完记得： bash tools/bundle.sh reset"
    fi
    echo
    echo "改完需重新构建： bash tools/build.sh"
    ;;
esac
