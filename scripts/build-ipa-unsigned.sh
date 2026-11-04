#!/usr/bin/env bash
#
# build-ipa-unsigned.sh — 只做 archive + 打包，不做签名、不做导出
#
# 这个脚本是 CI（.github/workflows/ios-build.yml）与「本地无证书出包」共用的
# 同一段流水线：产物是带 Payload/ 结构的标准 .ipa，但没有签名，
# 必须用 Sideloadly / AltStore 之类的工具拿你自己的 Apple ID 重签后才能安装。
#
# 用法：
#   ./scripts/build-ipa-unsigned.sh
#   ./scripts/build-ipa-unsigned.sh --configuration Debug
#   ./scripts/build-ipa-unsigned.sh --configuration Release --output build/x.ipa
#
# 依赖：macOS + Xcode（xcodebuild）+ xcodegen
# 兼容：macOS 自带 bash 3.2（不使用关联数组、mapfile、${var,,}）
#
# 与 build-ipa.sh 的关系：两个脚本的 unsigned 分支使用完全相同的
# xcodebuild 参数集合。改动其中一处时请同步另一处，保证「本地跑出来的」
# 与「CI 跑出来的」是同一种包。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROJECT_NAME="MeetingKit"
SCHEME="MeetingKit"
APP_NAME="MeetingKit"
TOTAL_STEPS=5

CONFIGURATION="Release"
OUTPUT_PATH=""

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_DIM=$'\033[2m'
    C_INFO=$'\033[36m'
    C_OK=$'\033[32m'
    C_ERR=$'\033[31m'
    C_BOLD=$'\033[1m'
    C_OFF=$'\033[0m'
else
    C_DIM=""
    C_INFO=""
    C_OK=""
    C_ERR=""
    C_BOLD=""
    C_OFF=""
fi

step() {
    local number="$1"
    shift
    printf '\n%s[%s/%s]%s %s%s%s…\n' \
        "$C_INFO" "$number" "$TOTAL_STEPS" "$C_OFF" "$C_BOLD" "$*" "$C_OFF"
}

info() {
    printf '        %s%s%s\n' "$C_DIM" "$*" "$C_OFF"
}

ok() {
    printf '        %s✓%s %s\n' "$C_OK" "$C_OFF" "$*"
}

die() {
    printf '\n%s✗ 错误：%s\n  %s\n\n' "$C_ERR" "$C_OFF" "$*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
用法：./scripts/build-ipa-unsigned.sh [--configuration Debug|Release] [--output <路径>]

  --configuration  构建配置，默认 Release
  --output         自定义 IPA 输出路径，默认 build/MeetingKit-<配置>-unsigned-<时间戳>.ipa
  -h, --help       显示本帮助

产物未签名，需要 Sideloadly / AltStore 用你自己的 Apple ID 重签后才能安装。
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --configuration)
            [ "$#" -ge 2 ] || die "参数 --configuration 缺少值（Debug 或 Release）"
            CONFIGURATION="$2"
            shift 2
            ;;
        --configuration=*)
            CONFIGURATION="${1#*=}"
            shift
            ;;
        --output)
            [ "$#" -ge 2 ] || die "参数 --output 缺少值（IPA 输出路径）"
            OUTPUT_PATH="$2"
            shift 2
            ;;
        --output=*)
            OUTPUT_PATH="${1#*=}"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            die "未知参数：$1"
            ;;
    esac
done

case "$CONFIGURATION" in
    Debug|Release) ;;
    *) die "非法配置：$CONFIGURATION（只接受 Debug 或 Release）" ;;
esac

STAMP="$(date +%Y%m%d-%H%M)"
BUILD_DIR="${PROJECT_ROOT}/build"
PROJECT_PATH="${PROJECT_ROOT}/${PROJECT_NAME}.xcodeproj"
ARCHIVE_PATH="${BUILD_DIR}/${PROJECT_NAME}.xcarchive"
APP_BUNDLE="${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app"

if [ -z "$OUTPUT_PATH" ]; then
    OUTPUT_PATH="${BUILD_DIR}/${APP_NAME}-${CONFIGURATION}-unsigned-${STAMP}.ipa"
fi

# ---------- [1/5] 环境检查 ----------

step 1 "环境检查"

[ "$(uname -s)" = "Darwin" ] || die "只能在 macOS 上运行（当前：$(uname -s)）。CI 请使用 macos-15 runner。"

command -v xcodebuild >/dev/null 2>&1 || die "未找到 xcodebuild。请安装 Xcode：sudo xcode-select -s /Applications/Xcode.app"
command -v xcodegen >/dev/null 2>&1 || die "未找到 xcodegen。安装：brew install xcodegen"
command -v zip >/dev/null 2>&1 || die "未找到 zip 命令。"

ok "$(xcodebuild -version 2>/dev/null | head -n 1)"
ok "xcodegen $(xcodegen --version 2>/dev/null | head -n 1 | sed 's/^Version: *//')"
ok "目标：${CONFIGURATION} / unsigned"

# ---------- [2/5] 生成 Xcode 工程 ----------

step 2 "生成 Xcode 工程"

info "xcodegen generate --spec project.yml"
if ! ( cd "$PROJECT_ROOT" && xcodegen generate --spec project.yml ); then
    die "xcodegen 生成工程失败，请检查 project.yml 是否与已安装的 xcodegen 版本兼容。"
fi
[ -d "$PROJECT_PATH" ] || die "生成后仍未找到 ${PROJECT_NAME}.xcodeproj"
ok "已生成 ${PROJECT_NAME}.xcodeproj"

# ---------- [3/5] 归档 ----------

step 3 "归档（archive，配置 ${CONFIGURATION}）"

rm -rf "$ARCHIVE_PATH"
mkdir -p "$BUILD_DIR"

info "CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=\"\""

XCODEBUILD_ARGS=(
    archive
    -project "$PROJECT_PATH"
    -scheme "$SCHEME"
    -configuration "$CONFIGURATION"
    -destination "generic/platform=iOS"
    -archivePath "$ARCHIVE_PATH"
)

if ! xcodebuild "${XCODEBUILD_ARGS[@]}" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGN_IDENTITY="" 2>&1 | tee "${BUILD_DIR}/archive.log"; then
    die "归档失败，完整日志：${BUILD_DIR}/archive.log"
fi

[ -d "$APP_BUNDLE" ] || die "归档里找不到 ${APP_NAME}.app（${APP_BUNDLE}）。请确认 project.yml 的 PRODUCT_NAME。"
ok "已生成 ${ARCHIVE_PATH}"

# ---------- [4/5] 打包 IPA ----------

step 4 "打包 IPA（Payload/ + zip → .ipa）"

STAGE_DIR="${BUILD_DIR}/ipa-stage"
RAW_ZIP="${BUILD_DIR}/${APP_NAME}-${CONFIGURATION}-${STAMP}.zip"

rm -rf "$STAGE_DIR"
mkdir -p "${STAGE_DIR}/Payload"
cp -R "$APP_BUNDLE" "${STAGE_DIR}/Payload/"

rm -f "$RAW_ZIP"
# -y 保留符号链接，-r 递归，-q 静默
if ! ( cd "$STAGE_DIR" && zip -qry "$RAW_ZIP" Payload ); then
    die "打包 zip 失败。"
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"
mv -f "$RAW_ZIP" "$OUTPUT_PATH"
rm -rf "$STAGE_DIR"
ok "已写出未签名 IPA"

# ---------- [5/5] 校验产物 ----------

step 5 "校验产物"

[ -f "$OUTPUT_PATH" ] || die "未生成 IPA：${OUTPUT_PATH}"

SIZE_BYTES="$(wc -c < "$OUTPUT_PATH" | tr -d ' ')"
SIZE_MB="$(awk -v bytes="$SIZE_BYTES" 'BEGIN { printf "%.1f", bytes / 1048576 }')"

if command -v unzip >/dev/null 2>&1; then
    if unzip -l "$OUTPUT_PATH" 2>/dev/null | grep -q "Payload/${APP_NAME}.app/Info.plist"; then
        ok "包结构正确：Payload/${APP_NAME}.app/Info.plist"
    else
        die "包结构异常：找不到 Payload/${APP_NAME}.app/Info.plist"
    fi
fi

ok "大小 ${SIZE_MB} MB"

printf '\n%s────────────────────────────────────────────%s\n' "$C_DIM" "$C_OFF"
printf '  %s产物%s  %s\n' "$C_BOLD" "$C_OFF" "$OUTPUT_PATH"
printf '  %s大小%s  %s MB\n' "$C_BOLD" "$C_OFF" "$SIZE_MB"
printf '  %s签名%s  未签名（需自行重签）\n' "$C_BOLD" "$C_OFF"
printf '%s────────────────────────────────────────────%s\n' "$C_DIM" "$C_OFF"
printf '\n安装：用 Sideloadly / AltStore 打开该 .ipa，填自己的 Apple ID 重签。\n'
printf '      免费账号 7 天过期；App Groups 能力可能不被免费账号支持。\n\n'
