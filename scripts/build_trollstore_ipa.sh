#!/usr/bin/env bash
#
# Jev Jarvis —— 打包成 TrollStore 可安装的 IPA
#
# 产出: out/JevJarvis-trollstore.ipa
# 结构: Payload/JevJarvis.app
#         Payload/JevJarvis.app/PlugIns/JevKeyboard.appex
#
# 关键点:
#   1. 主二进制与键盘扩展二进制都要用 ldid 做 fakesign，
#      TrollStore 重签时会保留 entitlements（含 App Group）。
#   2. 必须保留 PlugIns/JevKeyboard.appex，否则系统里根本不会
#      出现「Jev 键盘」这个键盘扩展。
#   3. 打包顺序：先 fakesign 再 zip，签名必须落在 zip 之前。
#
# 依赖: ldid (brew install ldid)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${ROOT}/out"
ENTS="${ROOT}/scripts/trollstore.entitlements"

APP_BUNDLE="JevJarvis.app"
APEX_NAME="JevKeyboard.appex"
MAIN_BIN="JevJarvis"
EX_BIN="JevKeyboard"

# 定位编译产物：优先 CI 用的 build/，其次扫 DerivedData。
find_products() {
  local c
  for c in "${ROOT}/build/Build/Products/Release-iphoneos" \
           "${ROOT}/build/Build/Products/Debug-iphoneos"; do
    if [ -d "${c}/${APP_BUNDLE}" ]; then echo "$c"; return 0; fi
  done
  c="$(find "${HOME}/Library/Developer/Xcode/DerivedData" -maxdepth 4 \
        -type d -name "Release-iphoneos" 2>/dev/null | head -1)"
  if [ -n "$c" ] && [ -d "${c}/${APP_BUNDLE}" ]; then echo "$c"; return 0; fi
  return 1
}

log() { printf '\033[1;36m[build]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 0. 前置检查 ----------
command -v ldid >/dev/null 2>&1 || die "未找到 ldid。请先执行: brew install ldid"
[ -f "$ENTS" ] || die "缺少 entitlements 文件: $ENTS"

BUILD_DIR="$(find_products)" || die "未找到编译产物 ${APP_BUNDLE}
请先执行 xcodebuild 编译（见 docs/TROLLSTORE_GUIDE.md）"
SRC_APP="${BUILD_DIR}/${APP_BUNDLE}"
log "编译产物: $SRC_APP"

# ---------- 1. 组装 Payload ----------
rm -rf "${OUT_DIR}/Payload"
mkdir -p "${OUT_DIR}/Payload"
cp -R "$SRC_APP" "${OUT_DIR}/Payload/"
log "已拷贝 ${APP_BUNDLE} 到 Payload/"

APPEX="${OUT_DIR}/Payload/${APP_BUNDLE}/PlugIns/${APEX_NAME}"

# 兜底：某些 xcodebuild 组合下 Embed Foundation Extensions 阶段没跑，
# 此时从 Products 目录把 appex 补进 PlugIns（其 Info.plist 本身是正确的）。
if [ ! -d "$APPEX" ]; then
  STANDALONE="${BUILD_DIR}/${APEX_NAME}"
  if [ -d "$STANDALONE" ]; then
    log "PlugIns 缺失，从 Products 目录补入 ${APEX_NAME}"
    mkdir -p "${OUT_DIR}/Payload/${APP_BUNDLE}/PlugIns"
    cp -R "$STANDALONE" "$APPEX"
  else
    die "既没有 ${APPEX} 也没有 ${STANDALONE}，键盘扩展构建失败"
  fi
fi
[ -d "$APPEX" ] || die "键盘扩展 appex 缺失"

# ---------- 2. fakesign（主 App + 键盘扩展）----------
log "fakesign 主程序 ${MAIN_BIN}"
ldid -S"$ENTS" "${OUT_DIR}/Payload/${APP_BUNDLE}/${MAIN_BIN}"

log "fakesign 键盘扩展 ${EX_BIN}"
ldid -S"$ENTS" "${APPEX}/${EX_BIN}"

# ---------- 3. 打包 IPA ----------
cd "$OUT_DIR"
rm -f JevJarvis-trollstore.ipa

if command -v zip >/dev/null 2>&1; then
  # -y 保留符号链接（Frameworks 内的软链必须原样保留）
  zip -qry JevJarvis-trollstore.ipa Payload \
    -x '*.DS_Store' '*/__MACOSX/*' '*/._*'
else
  # 兜底：精简环境可能没装 zip，用 python3 打包
  log "未找到 zip，改用 python3 打包"
  python3 - <<'PY'
import os, zipfile
with zipfile.ZipFile("JevJarvis-trollstore.ipa", "w", zipfile.ZIP_DEFLATED) as z:
    for root, dirs, files in os.walk("Payload"):
        for name in files:
            if name == ".DS_Store" or name.startswith("._"):
                continue
            p = os.path.join(root, name)
            z.write(p, p)
PY
fi
[ -f JevJarvis-trollstore.ipa ] || die "IPA 打包失败"
log "已生成 out/JevJarvis-trollstore.ipa"

# ---------- 4. 自检 ----------
echo
log "IPA 内容结构:"
unzip -l JevJarvis-trollstore.ipa \
  | grep -E 'Payload/[^/]+/$|Payload/[^/]+/[^/]+$|PlugIns' | head -20
echo
log "entitlements 校验（主程序）:"
ldid -e "${OUT_DIR}/Payload/${APP_BUNDLE}/${MAIN_BIN}" \
  | tr -d '\0' | grep -A2 'application-groups' || true
log "entitlements 校验（键盘扩展）:"
ldid -e "$APPEX/${EX_BIN}" \
  | tr -d '\0' | grep -A2 'application-groups' || true
echo
log "完成。把 out/JevJarvis-trollstore.ipa 传到 iPhone，用 TrollStore 打开安装。"
