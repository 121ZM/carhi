#!/usr/bin/env bash
# CarHi（HarmonyOS CarLife 手机端）签名工具
#
# 子命令：
#   genkey           生成本地私钥库 + CSR（首次申请证书时跑一次）
#   sign [release]   用 certs/ 里的证书给未签名 HAP 签名（默认 debug）
#   verify           校验已签名 HAP 的签名链与 Profile
#   inspect [p12] [storePwd] [p7b]   检查密钥库：别名、自带证书链、与 Profile 是否配对
#   status           查看 certs/ 当前有哪些材料
#
# 依赖：Command Line Tools 里的 hap-sign-tool.jar + 一个 JDK(11+)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERTS="$ROOT/certs"
HARMONY="$ROOT/harmony"
CLT_HOME="${CLT_HOME:-E:/AITools/command-line-tools}"
SIGN_TOOL="$CLT_HOME/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar"

# ---------------- JDK ----------------
if [ -z "${JAVA_HOME:-}" ]; then
  for candidate in \
      "C:/Users/dev/.jdks/jbr_dcevm-11.0.16" \
      "C:/Program Files/Java/jdk-17" \
      "C:/Program Files/Java/jdk-11" ; do
    if [ -x "$candidate/bin/java.exe" ] || [ -x "$candidate/bin/java" ]; then
      JAVA_HOME="$candidate"; break
    fi
  done
fi
[ -n "${JAVA_HOME:-}" ] || { echo "ERROR: 找不到 JDK，请设置 JAVA_HOME" >&2; exit 1; }
JAVA_EXE="$JAVA_HOME/bin/java.exe"
[ -x "$JAVA_EXE" ] || JAVA_EXE="$JAVA_HOME/bin/java"

sign_tool() { "$JAVA_EXE" -jar "$SIGN_TOOL" "$@"; }

[ -f "$SIGN_TOOL" ] || { echo "ERROR: 找不到签名工具 $SIGN_TOOL" >&2; exit 1; }
mkdir -p "$CERTS"

# 临时目录放在项目内：Windows 下的系统临时目录（C:\...）会被安全钩子拦下 rm，
# 导致脚本返回非 0。用项目相对路径就没这个问题。
_mktmp() {
  local d="$ROOT/.tmp-sign"
  rm -rf "$d" 2>/dev/null || true
  mkdir -p "$d"
  echo "$d"
}

# ---------------- 可覆盖的签名参数 ----------------
# 密码绝不写死在脚本里（本仓库是公开的）。
# 来源优先级：环境变量 CARHI_KEY_PWD > certs/keystore.pwd（已被 .gitignore 挡住，不入 git）
if [ -z "${CARHI_KEY_PWD:-}" ] && [ -f "$CERTS/keystore.pwd" ]; then
  CARHI_KEY_PWD="$(tr -d '\r\n' < "$CERTS/keystore.pwd")"
fi
CARHI_KEY_ALIAS="${CARHI_KEY_ALIAS:-carhi-key-v1}"
CARHI_STORE_PWD="${CARHI_STORE_PWD:-${CARHI_KEY_PWD:-}}"
CARHI_SUBJECT="${CARHI_SUBJECT:-C=CN,O=CarHi,OU=CarHi Dev,CN=CarHi CarLife Phone}"

# 需要密码的子命令在缺密码时统一报错，而不是拿一个默认值去试
require_pwd() {
  if [ -z "${CARHI_KEY_PWD:-}" ]; then
    echo "ERROR: 未提供密钥库密码。" >&2
    echo "       用环境变量传入：  CARHI_KEY_PWD='你的密码' bash tools/sign.sh $1" >&2
    echo "       或写入 certs/keystore.pwd（该文件已在 .gitignore 中，不会提交）" >&2
    exit 1
  fi
}

# ---------------- 子命令 ----------------
cmd_genkey() {
  require_pwd genkey
  if [ -f "$CERTS/keystore.p12" ]; then
    echo "!! $CERTS/keystore.p12 已存在。" >&2
    echo "   重新生成会让 AGC 上已签发的证书全部失效（公钥对不上）。" >&2
    echo "   确实要重来，请先手动删掉它。" >&2
    exit 1
  fi

  echo "==> 生成密钥对（ECC NIST-P-256）"
  sign_tool generate-keypair \
    -keyAlias "$CARHI_KEY_ALIAS" \
    -keyPwd "$CARHI_KEY_PWD" \
    -keyAlg ECC -keySize NIST-P-256 \
    -keystoreFile "$CERTS/keystore.p12" \
    -keystorePwd "$CARHI_STORE_PWD" >/dev/null

  echo "==> 生成证书签名请求 CSR"
  sign_tool generate-csr \
    -keyAlias "$CARHI_KEY_ALIAS" \
    -keyPwd "$CARHI_KEY_PWD" \
    -subject "$CARHI_SUBJECT" \
    -signAlg SHA256withECDSA \
    -keystoreFile "$CERTS/keystore.p12" \
    -keystorePwd "$CARHI_STORE_PWD" \
    -outFile "$CERTS/carhi.csr" >/dev/null

  echo "$CARHI_KEY_PWD" > "$CERTS/keystore.pwd"
  echo
  echo "==> 完成"
  echo "   私钥库 : $CERTS/keystore.p12   （别名 $CARHI_KEY_ALIAS，密码已存 certs/keystore.pwd）"
  echo "   CSR    : $CERTS/carhi.csr      ← 把这个上传到 AGC 申请证书"
  echo
  echo "下一步：登录 AGC → 证书管理 → 新增证书 → 上传 carhi.csr → 下载 .cer"
  echo "        然后 Profile 管理 → 新增 Profile（调试需先注册真机 UDID）→ 下载 .p7b"
}

cmd_sign() {
  require_pwd sign
  local mode="${1:-debug}"
  local cer profile out

  case "$mode" in
    debug|debug)
      cer="$CERTS/carhi-debug.cer";   profile="$CERTS/carhi-debug.p7b" ;;
    release|正式)
      cer="$CERTS/carhi-release.cer"; profile="$CERTS/carhi-release.p7b" ;;
    *) echo "未知模式: $mode（用 debug 或 release）" >&2; exit 2 ;;
  esac

  local unsigned="$HARMONY/entry/build/default/outputs/default/entry-default-unsigned.hap"
  [ -f "$unsigned" ] || { echo "ERROR: 找不到未签名 HAP：$unsigned" >&2
    echo "       先跑 bash tools/build.sh" >&2; exit 1; }

  [ -f "$cer" ]     || { echo "ERROR: 缺少证书    $cer"     >&2; _hint; exit 1; }
  [ -f "$profile" ] || { echo "ERROR: 缺少 Profile $profile" >&2; _hint; exit 1; }

  out="$HARMONY/entry/build/default/outputs/default/entry-default-signed-$mode.hap"

  echo "==> 签名模式: $mode"
  echo "    keystore: $CERTS/keystore.p12"
  echo "    别名    : $CARHI_KEY_ALIAS"
  echo "    证书    : $cer"
  echo "    Profile : $profile"

  sign_tool sign-app -mode localSign \
    -keyAlias "$CARHI_KEY_ALIAS" \
    -keyPwd "$CARHI_KEY_PWD" \
    -appCertFile "$cer" \
    -profileFile "$profile" \
    -inFile "$unsigned" \
    -signAlg SHA256withECDSA \
    -keystoreFile "$CERTS/keystore.p12" \
    -keystorePwd "$CARHI_STORE_PWD" \
    -outFile "$out" \
    -compatibleVersion 12 \
    -signCode 1

  echo
  echo "==> 产物: $out"
  ls -la "$out"
}

cmd_verify() {
  local target="${1:-}"
  if [ -z "$target" ]; then
    target="$(ls -t "$HARMONY"/entry/build/default/outputs/default/*signed*.hap 2>/dev/null | head -1 || true)"
  fi
  [ -n "$target" ] && [ -f "$target" ] || { echo "没找到已签名的 HAP" >&2; exit 1; }

  local tmp; tmp="$(_mktmp)"
  echo "==> 校验: $target"
  if sign_tool verify-app -inFile "$target" \
       -outCertChain "$tmp/chain.cer" -outProfile "$tmp/profile.p7b"; then
    echo
    echo "==> 签名链:"
    grep -c "BEGIN CERTIFICATE" "$tmp/chain.cer" | sed 's/^/    证书数量: /'
    "$JAVA_HOME/bin/keytool.exe" -printcert -file "$tmp/chain.cer" 2>/dev/null \
      | grep -a "CN=" | sed 's/^/    /' || true
    echo
    echo "==> Profile 概要:"
    python - "$tmp/profile.p7b" <<'PY' 2>/dev/null || true
import sys
d = open(sys.argv[1], 'rb').read()
i = d.find(b'{"version-name"')
if i < 0:
    sys.exit(0)
depth = 0
for k in range(i, len(d)):
    if d[k:k+1] == b'{': depth += 1
    elif d[k:k+1] == b'}':
        depth -= 1
        if depth == 0:
            j = k + 1; break
import json
p = json.loads(d[i:j].decode('utf-8', 'replace'))
print('    type      :', p.get('type'))
print('    bundle    :', p.get('bundle-info', {}).get('bundle-name'))
dev = p.get('debug-info')
if dev:
    print('    绑定设备数:', len(dev.get('device-ids', [])))
PY
  else
    echo "!! 校验失败" >&2
    rm -rf "$tmp" 2>/dev/null || true; exit 1
  fi
  rm -rf "$tmp" 2>/dev/null || true
}

cmd_inspect() {
  # 检查一份 p12：列出别名、导出证书链、与已有 p7b 里嵌的开发证书比对指纹。
  # 用途：从旧机器找回密钥库后，确认它能不能复用。
  # keytool 强制英文输出（-J-Duser.language=en），避免中文在 GBK/UTF-8 间乱码导致解析失败。
  local p12="${1:-$CERTS/keystore.p12}"
  [ -f "$p12" ] || { echo "ERROR: 找不到 $p12" >&2; exit 1; }

  local KT=("$JAVA_HOME/bin/keytool.exe" -J-Duser.language=en -J-Duser.country=US)
  local storePwd="${2:-${CARHI_STORE_PWD:-}}"
  echo "==> 检查密钥库: $p12"
  echo "    大小: $(wc -c < "$p12") bytes"
  echo

  # 密码未知时试几个常见值（DevEco 自动签名常用）
  local ok=""
  local p
  for p in "$storePwd" "$CARHI_STORE_PWD" "123456" "000000" ""; do
    if "${KT[@]}" -list -keystore "$p12" -storetype PKCS12 \
         -storepass "$p" >/dev/null 2>&1; then ok="$p"; break; fi
  done
  if [ -z "$ok" ] && ! "${KT[@]}" -list -keystore "$p12" -storetype PKCS12 \
         -storepass "$ok" >/dev/null 2>&1; then
    echo "!! 无法打开：密码不对（或不是 PKCS12 格式）。" >&2
    echo "   请显式提供：bash tools/sign.sh inspect <p12> <storePassword>" >&2
    exit 1
  fi
  echo "    可用密码: ${ok:-（空）}"
  echo

  local listing
  listing="$("${KT[@]}" -list -v -keystore "$p12" -storetype PKCS12 -storepass "$ok" 2>/dev/null || true)"

  echo "==> 条目列表:"
  echo "$listing" | grep -a -E "^Alias name:|^Entry type:|^Certificate chain length:" \
    | sed 's/^/    /' || true
  echo

  local tmp; tmp="$(_mktmp)"
  local aliases
  aliases="$(echo "$listing" | grep -a "^Alias name:" \
    | sed 's/^Alias name:[[:space:]]*//' | tr -d '\r' || true)"

  local a n
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    echo "==> 别名: $a"
    "${KT[@]}" -list -rfc -alias "$a" -keystore "$p12" -storetype PKCS12 \
      -storepass "$ok" 2>/dev/null \
      | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' > "$tmp/c-$a.pem" || true
    n="$(grep -c 'BEGIN CERTIFICATE' "$tmp/c-$a.pem" 2>/dev/null || true)"
    n="${n:-0}"
    echo "    自带证书链长度: $n"
    if [ "$n" -ge 3 ]; then
      echo "    [OK] 链够长，可直接当 -appCertFile 用"
    elif [ "$n" -gt 0 ]; then
      echo "    [!] 只有 $n 级；签 HAP 需要 >= 3 级（三级-二级-根），还得配 AGC 的 .cer"
    else
      echo "    [!] 只有私钥、没有证书 -> 需要 AGC 那张 .cer"
    fi
    if [ "$n" -gt 0 ]; then
      "${KT[@]}" -printcert -file "$tmp/c-$a.pem" 2>/dev/null \
        | grep -a -E "^Owner:|^Issuer:" | sed 's/^/      /' || true
      [ -f "$tmp/chain.pem" ] || cp "$tmp/c-$a.pem" "$tmp/chain.pem"
    fi
    echo
  done <<< "$aliases"

  # 与 p7b 里嵌的开发证书比对指纹
  local p7b="${3:-}"
  if [ -z "$p7b" ]; then
    p7b="$(ls "$CERTS"/*.p7b 2>/dev/null | head -1 || true)"
  fi
  if [ -z "$p7b" ] || [ ! -f "$p7b" ]; then
    [ -f "$ROOT/HomeGameDebug.p7b" ] && p7b="$ROOT/HomeGameDebug.p7b"
  fi
  if [ -n "$p7b" ] && [ -f "$p7b" ] && [ -f "$tmp/chain.pem" ]; then
    echo "==> 与 Profile 内嵌开发证书比对: $p7b"
    python - "$p7b" "$tmp/chain.pem" <<'PY' 2>/dev/null || echo "    （比对失败）"
import sys, hashlib, base64
d = open(sys.argv[1], 'rb').read()
i = d.find(b'-----BEGIN CERTIFICATE-----')
j = d.find(b'-----END CERTIFICATE-----')
emb = d[i:j+25].decode('ascii', 'replace') if i >= 0 else ''
def fp(pem):
    try:
        b = pem.split('-----BEGIN CERTIFICATE-----')[1].split('-----END CERTIFICATE-----')[0]
        return hashlib.sha256(base64.b64decode(''.join(b.split()))).hexdigest()
    except Exception:
        return ''
a = fp(emb)
b = fp(open(sys.argv[2]).read())
print('    Profile 内嵌证书 sha256 :', (a[:32] + '...') if a else '(无)')
print('    p12 里第一张证书 sha256 :', (b[:32] + '...') if b else '(无)')
print('    是否同一张证书          :', 'YES 配对成功' if a and a == b else 'NO 不匹配')
PY
  fi
  rm -rf "$tmp" 2>/dev/null || true
}

cmd_status() {
  echo "==> JDK        : $JAVA_HOME"
  echo "==> 签名工具   : $SIGN_TOOL"
  echo
  echo "==> certs/ 内容:"
  local found=0
  for f in keystore.p12 keystore.pwd carhi.csr \
           carhi-debug.cer carhi-debug.p7b carhi-release.cer carhi-release.p7b; do
    if [ -f "$CERTS/$f" ]; then
      printf "    [x] %-20s %8s bytes\n" "$f" "$(wc -c < "$CERTS/$f")"; found=1
    else
      printf "    [ ] %-20s --\n" "$f"
    fi
  done
  [ "$found" = "1" ] || echo "    （空）"
  echo
  local unsigned="$HARMONY/entry/build/default/outputs/default/entry-default-unsigned.hap"
  if [ -f "$unsigned" ]; then
    echo "==> 待签名 HAP: $unsigned"
  else
    echo "==> 待签名 HAP: 尚未构建（跑 bash tools/build.sh）"
  fi
}

_hint() {
  echo
  echo "  申请流程见 certs/README.md："
  echo "    bash tools/sign.sh genkey     # 生成 p12 + csr"
  echo "    → AGC 上传 csr 换 .cer，建 Profile 换 .p7b"
  echo "    → 放到 certs/ 后 bash tools/sign.sh $mode"
}

# ---------------- 分发 ----------------
case "${1:-status}" in
  genkey)          shift; cmd_genkey "$@" ;;
  sign)            shift; cmd_sign "$@" ;;
  verify)          shift; cmd_verify "$@" ;;
  inspect)         shift; cmd_inspect "$@" ;;
  status)          shift; cmd_status "$@" ;;
  -h|--help|help)  sed -n '2,/^$/p' "$0" ;;
  *) echo "未知子命令: $1" >&2; sed -n '2,/^$/p' "$0"; exit 2 ;;
esac
