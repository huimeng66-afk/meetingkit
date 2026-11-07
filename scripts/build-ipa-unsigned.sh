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
TOTAL_STEPS=6

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

# ---------- ScreenCaptureKit 的链接方式 ----------
# iOS 27 起 Apple 用 ScreenCaptureKit 取代了广播扩展，但那个 framework
# 只存在于 iOS 27 SDK 里：
#   · 构建机是 Xcode 26（macos-15 / macos-26 镜像都如此）：
#     framework 根本不存在，告诉链接器 -weak_framework 会直接失败。
#   · 构建机是 Xcode 27：必须弱链接，否则产物在 iOS 26 设备上
#     dyld 找不到框架，App 启动即崩。
# 所以这里按实际 SDK 版本决定，不写死在 project.yml 里。
SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || echo 0)"
SDK_MAJOR="${SDK_VERSION%%.*}"
info "iOS SDK：${SDK_VERSION}"

EXTRA_BUILD_SETTINGS=()
if [ "${SDK_MAJOR:-0}" -ge 27 ] 2>/dev/null; then
    info "SDK >= 27：ScreenCaptureKit 参与编译（弱链接）"
    EXTRA_BUILD_SETTINGS+=("OTHER_LDFLAGS=-weak_framework ScreenCaptureKit")
else
    info "SDK < 27：ScreenCaptureKit 不参与编译，共享回退到 ReplayKit in-app 捕获"
fi

if ! xcodebuild "${XCODEBUILD_ARGS[@]}" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGN_IDENTITY="" \
        ${EXTRA_BUILD_SETTINGS[@]+"${EXTRA_BUILD_SETTINGS[@]}"} 2>&1 | tee "${BUILD_DIR}/archive.log"; then
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

# ---------- [附加] CI 环境：把产物推送到 builds 分支 ----------
#
# 为什么是 git push，而不是 Release / Actions Artifact：
#   使用 fine-grained PAT 时，"Actions" 与 "Contents" 是两套独立权限。
#   只授权 Contents 的令牌能拉代码、能 push，却完全读不到构建产物
#   （GET /repositories/{id}/actions/artifacts 直接 403 "Resource not
#   accessible by personal access token"），也读不到 workflow run。
#   而 actions/checkout 已经把令牌写进了 git 的 http.extraheader，
#   所以脚本天然具备 push 能力 —— 把包推到专门的 builds 分支，
#   取包只需要 clone 这一个分支，与 Actions 权限无关。
#
# 为什么用临时 index + commit-tree：
#   1. 不碰工作区，不影响本步之后的任何逻辑；
#   2. build/ 一般在 .gitignore 里，常规 git add 根本加不进去，
#      --cacheinfo 可以绕过 ignore 规则；
#   3. 造出来的是孤立提交，不带历史，分支每次 force push 即可，
#      仓库体积不会随构建次数线性增长（旧的 blob 会被 gc）。
publish_to_builds_branch() {
    [ -n "${GITHUB_ACTIONS:-}" ] || return 0
    [ -n "${GITHUB_REF_NAME:-}" ] || return 0

    local version build_number asset_name tmp_index info_file
    local blob info_blob tree commit branch
    branch="builds"

    version="$(sed -n 's/.*MARKETING_VERSION: *"\([^"]*\)".*/\1/p' "${PROJECT_ROOT}/project.yml" | head -1)"
    build_number="$(sed -n 's/.*CURRENT_PROJECT_VERSION: *"\([^"]*\)".*/\1/p' "${PROJECT_ROOT}/project.yml" | head -1)"
    [ -n "$version" ] || version="dev"
    [ -n "$build_number" ] || build_number="0"

    asset_name="${APP_NAME}-${version}-unsigned.ipa"

    step 6 "发布产物到 ${branch} 分支"

    tmp_index="$(mktemp -t mk-builds-index)"
    info_file="$(mktemp -t mk-builds-info)"
    GIT_INDEX_FILE="$tmp_index" git read-tree --empty

    blob="$(git hash-object -w "$OUTPUT_PATH")"
    GIT_INDEX_FILE="$tmp_index" git update-index --add --cacheinfo "100644,${blob},${asset_name}"

    cat > "$info_file" <<INFO
{
  "app": "${APP_NAME}",
  "version": "${version}",
  "build": "${build_number}",
  "configuration": "${CONFIGURATION}",
  "asset": "${asset_name}",
  "size_bytes": ${SIZE_BYTES},
  "signed": false,
  "commit": "${GITHUB_SHA:-unknown}",
  "ref": "${GITHUB_REF_NAME}",
  "run_id": "${GITHUB_RUN_ID:-unknown}",
  "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
INFO
    info_blob="$(git hash-object -w "$info_file")"
    GIT_INDEX_FILE="$tmp_index" git update-index --add --cacheinfo "100644,${info_blob},build-info.json"

    tree="$(GIT_INDEX_FILE="$tmp_index" git write-tree)"
    commit="$(GIT_AUTHOR_NAME="MeetingKit CI" GIT_AUTHOR_EMAIL="ci@localhost" \
              GIT_COMMITTER_NAME="MeetingKit CI" GIT_COMMITTER_EMAIL="ci@localhost" \
              git commit-tree "$tree" -m "build: ${asset_name} (${GITHUB_SHA:-unknown})")"

    if git push --force origin "${commit}:refs/heads/${branch}" 2>&1; then
        ok "已推送 ${asset_name} → ${branch} 分支"
    else
        rm -f "$tmp_index" "$info_file"
        die "推送 ${branch} 分支失败，产物无法取回"
    fi

    rm -f "$tmp_index" "$info_file"
}

# 非 CI 环境（本地跑）直接跳过，不能把本地出包当成发布。
# 用 if 而不是 `|| true`：函数放进条件上下文会让 set -e 失效，
# 里面任何一条命令失败都会被吞掉，最后推上去一个残缺提交。
if [ -n "${GITHUB_ACTIONS:-}" ]; then
    publish_to_builds_branch
fi
