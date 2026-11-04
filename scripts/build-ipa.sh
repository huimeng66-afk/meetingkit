#!/usr/bin/env bash
#
# build-ipa.sh — macOS 本地一键出包
#
# 两种模式：
#   1. 无 --team  → 未签名 IPA（不需要任何证书，产物只能用于重签/归档）
#   2. 有 --team  → 自动签名 + 导出，产物可直接装到已注册设备
#
# 用法：
#   ./scripts/build-ipa.sh
#   ./scripts/build-ipa.sh --configuration Debug
#   ./scripts/build-ipa.sh --team ABCDE12345
#   ./scripts/build-ipa.sh --team ABCDE12345 --output ~/Desktop/MeetingKit.ipa
#
# 依赖：Xcode（xcodebuild）+ xcodegen（brew install xcodegen）
# 兼容：macOS 自带 bash 3.2 —— 不使用关联数组、mapfile、${var,,} 等 4.x 特性。
#
# 注意：本脚本只调用工程里已有的 project.yml / Info.plist / entitlements，
#       不会修改任何源码或配置。签名相关的 Team ID 一律从命令行传入，不写死。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROJECT_NAME="MeetingKit"
SCHEME="MeetingKit"
APP_NAME="MeetingKit"
TOTAL_STEPS=6

CONFIGURATION="Release"
TEAM_ID=""
OUTPUT_PATH=""

# ---------- 彩色输出（非 tty 或设置 NO_COLOR 时自动降级为纯文本） ----------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_DIM=$'\033[2m'
    C_INFO=$'\033[36m'
    C_OK=$'\033[32m'
    C_WARN=$'\033[33m'
    C_ERR=$'\033[31m'
    C_BOLD=$'\033[1m'
    C_OFF=$'\033[0m'
else
    C_DIM=""
    C_INFO=""
    C_OK=""
    C_WARN=""
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

warn() {
    printf '        %s!%s %s\n' "$C_WARN" "$C_OFF" "$*"
}

die() {
    printf '\n%s✗ 错误：%s\n' "$C_ERR" "$C_OFF" >&2
    printf '  %s\n\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
用法：./scripts/build-ipa.sh [选项]

选项：
  --team <TEAM_ID>        Apple Developer Team ID（10 位字母数字）。
                          提供后走自动签名 + exportArchive，产出可直接安装的 IPA。
                          不提供则走 unsigned 路径，产出需要第三方工具重签的 IPA。
  --configuration <名称>  构建配置：Debug 或 Release（默认 Release）
  --output <路径>         自定义 IPA 输出路径
                          默认 build/MeetingKit-<配置>-<yyyyMMdd-HHmm>.ipa
  -h, --help              显示本帮助

示例：
  ./scripts/build-ipa.sh
  ./scripts/build-ipa.sh --team ABCDE12345
  ./scripts/build-ipa.sh --configuration Debug --team ABCDE12345

说明：
  · Team ID 可在 Apple Developer 后台 Membership 页或
    `security find-identity -v -p codesigning` 的证书名括号里找到。
  · 首次使用自动签名需要 Xcode 已登录开发者账号
    （Xcode → Settings → Accounts）。
USAGE
}

# ---------- 参数解析 ----------

while [ "$#" -gt 0 ]; do
    case "$1" in
        --team)
            [ "$#" -ge 2 ] || die "参数 --team 缺少值（应为一个 10 位的 Team ID）"
            TEAM_ID="$2"
            shift 2
            ;;
        --team=*)
            TEAM_ID="${1#*=}"
            shift
            ;;
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

if [ -n "$TEAM_ID" ]; then
    SIGN_MODE="signed"
else
    SIGN_MODE="unsigned"
fi

if [ -n "$TEAM_ID" ]; then
    case "$TEAM_ID" in
        *[!A-Za-z0-9]*) die "Team ID 只应包含字母与数字：$TEAM_ID" ;;
    esac
    if [ "${#TEAM_ID}" -ne 10 ]; then
        warn "Team ID「$TEAM_ID」不是 10 位，通常应为 10 位（继续尝试）"
    fi
fi

STAMP="$(date +%Y%m%d-%H%M)"
BUILD_DIR="${PROJECT_ROOT}/build"
PROJECT_PATH="${PROJECT_ROOT}/${PROJECT_NAME}.xcodeproj"
ARCHIVE_PATH="${BUILD_DIR}/${PROJECT_NAME}.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
EXPORT_PLIST="${BUILD_DIR}/ExportOptions.plist"
ARCHIVE_LOG="${BUILD_DIR}/archive.log"

if [ -z "$OUTPUT_PATH" ]; then
    OUTPUT_PATH="${BUILD_DIR}/${APP_NAME}-${CONFIGURATION}-${STAMP}.ipa"
fi

printf '%sMeetingKit · iOS 打包%s  %s(%s / %s)%s\n' \
    "$C_BOLD" "$C_OFF" "$C_DIM" "$CONFIGURATION" "$SIGN_MODE" "$C_OFF"

# ---------- [1/6] 环境检查 ----------

step 1 "环境检查"

if [ "$(uname -s)" != "Darwin" ]; then
    die "本脚本只能在 macOS 上运行（当前系统：$(uname -s)）。
  iOS 二进制必须由 Apple 的 iOS SDK + Xcode 工具链产出，二者只在 macOS 上可用。
  没有 Mac 时请改用 GitHub Actions：docs/build-and-install.md 的「路径一」。"
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
    die "未找到 xcodebuild。
  请从 App Store 安装 Xcode，然后执行：
    sudo xcode-select -s /Applications/Xcode.app
    sudo xcodebuild -license accept"
fi

if ! command -v xcodegen >/dev/null 2>&1; then
    die "未找到 xcodegen。
  安装：brew install xcodegen
  若没有 Homebrew：https://brew.sh"
fi

if ! command -v zip >/dev/null 2>&1; then
    die "未找到 zip 命令（macOS 自带，缺失说明 PATH 异常）。"
fi

XCODE_VERSION_LINE="$(xcodebuild -version 2>/dev/null | head -n 1)"
ok "${XCODE_VERSION_LINE:-xcodebuild 已就绪}"
ok "xcodegen $(xcodegen --version 2>/dev/null | head -n 1 | sed 's/^Version: *//')"

if [ "$SIGN_MODE" = "signed" ]; then
    ok "签名模式：自动签名（Team ${TEAM_ID}）"
else
    ok "签名模式：unsigned（不做签名，不需要证书）"
fi

# ---------- [2/6] 生成 Xcode 工程 ----------

step 2 "生成 Xcode 工程"

info "xcodegen generate --spec project.yml"
if ! ( cd "$PROJECT_ROOT" && xcodegen generate --spec project.yml ); then
    die "xcodegen 生成工程失败。请检查 project.yml（尤其 minimumXcodeGenVersion）是否与已安装版本匹配。"
fi

[ -d "$PROJECT_PATH" ] || die "生成后仍未找到 ${PROJECT_NAME}.xcodeproj"
ok "已生成 ${PROJECT_NAME}.xcodeproj"

# ---------- [3/6] 清理旧产物 ----------

step 3 "清理旧产物"

rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR"
mkdir -p "$BUILD_DIR"
ok "已重置 build/ 中的归档与导出目录"
info "本次产物：${OUTPUT_PATH}"

# ---------- [4/6] 归档 ----------

step 4 "归档（archive，配置 ${CONFIGURATION}）"

XCODEBUILD_ARGS=(
    archive
    -project "$PROJECT_PATH"
    -scheme "$SCHEME"
    -configuration "$CONFIGURATION"
    -destination "generic/platform=iOS"
    -archivePath "$ARCHIVE_PATH"
)

if [ "$SIGN_MODE" = "signed" ]; then
    info "xcodebuild archive … DEVELOPMENT_TEAM=${TEAM_ID} -allowProvisioningUpdates"
    if ! xcodebuild "${XCODEBUILD_ARGS[@]}" \
            DEVELOPMENT_TEAM="$TEAM_ID" \
            CODE_SIGN_STYLE=Automatic \
            -allowProvisioningUpdates 2>&1 | tee "$ARCHIVE_LOG"; then
        die "归档失败（已签名）。完整日志：${ARCHIVE_LOG}
  常见原因：
    · Xcode 未登录开发者账号 → Xcode → Settings → Accounts
    · Team ID 与证书不匹配
    · 设备未注册到该 Team（development 描述文件只允许已注册设备）"
    fi
else
    info "xcodebuild archive … CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=\"\""
    if ! xcodebuild "${XCODEBUILD_ARGS[@]}" \
            CODE_SIGNING_ALLOWED=NO \
            CODE_SIGNING_REQUIRED=NO \
            CODE_SIGN_IDENTITY="" 2>&1 | tee "$ARCHIVE_LOG"; then
        die "归档失败（unsigned）。完整日志：${ARCHIVE_LOG}"
    fi
fi

[ -d "$ARCHIVE_PATH" ] || die "归档结束但未找到 ${ARCHIVE_PATH}"

APP_BUNDLE="${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app"
[ -d "$APP_BUNDLE" ] || die "归档中找不到 ${APP_NAME}.app：
  ${APP_BUNDLE}
  请确认 project.yml 里 PRODUCT_NAME 仍是 ${APP_NAME}。"
ok "已生成 ${ARCHIVE_PATH}"

# ---------- [5/6] 产出 IPA ----------

step 5 "产出 IPA"

mkdir -p "$(dirname "$OUTPUT_PATH")"

if [ "$SIGN_MODE" = "signed" ]; then
    info "写入 ExportOptions.plist（method=development，teamID=${TEAM_ID}）"
    # method=development 对应「开发分发」：只允许已注册设备安装。
    # Xcode 15+ 把这套命名改成了 debugging / release-testing，
    # 但 development 仍然被 xcodebuild 接受，此处按兼容性保留。
    cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>development</string>
	<key>teamID</key>
	<string>${TEAM_ID}</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>signingCertificate</key>
	<string>Apple Development</string>
	<key>stripSwiftSymbols</key>
	<true/>
	<key>compileBitcode</key>
	<false/>
	<key>destination</key>
	<string>export</string>
</dict>
</plist>
PLIST

    info "xcodebuild -exportArchive …"
    if ! xcodebuild -exportArchive \
            -archivePath "$ARCHIVE_PATH" \
            -exportOptionsPlist "$EXPORT_PLIST" \
            -exportPath "$EXPORT_DIR" \
            -allowProvisioningUpdates 2>&1 | tee "${BUILD_DIR}/export.log"; then
        die "导出签名 IPA 失败。完整日志：${BUILD_DIR}/export.log
  常见原因：
    · No signing certificate \"iOS Development\" found → 账号里没有开发证书
    · Provisioning profile doesn't support App Groups → 账号未启用 App Groups 能力
    · 设备未注册 → developer.apple.com 里补充设备后重新归档"
    fi

    EXPORTED_IPA=""
    if [ -f "${EXPORT_DIR}/${APP_NAME}.ipa" ]; then
        EXPORTED_IPA="${EXPORT_DIR}/${APP_NAME}.ipa"
    else
        for candidate in "${EXPORT_DIR}"/*.ipa; do
            if [ -f "$candidate" ]; then
                EXPORTED_IPA="$candidate"
                break
            fi
        done
    fi
    [ -n "$EXPORTED_IPA" ] || die "导出目录里没有 .ipa：${EXPORT_DIR}"

    mv -f "$EXPORTED_IPA" "$OUTPUT_PATH"
    ok "已导出签名 IPA"
else
    STAGE_DIR="${BUILD_DIR}/ipa-stage"
    RAW_ZIP="${BUILD_DIR}/${APP_NAME}-${CONFIGURATION}-${STAMP}.zip"

    info "组装 Payload/ 目录结构"
    rm -rf "$STAGE_DIR"
    mkdir -p "${STAGE_DIR}/Payload"
    cp -R "$APP_BUNDLE" "${STAGE_DIR}/Payload/"

    info "压缩为 zip 并改名为 .ipa"
    rm -f "$RAW_ZIP"
    # -y 保留符号链接（Frameworks 里可能是 link），-r 递归，-q 静默
    if ! ( cd "$STAGE_DIR" && zip -qry "$RAW_ZIP" Payload ); then
        die "打包 zip 失败。"
    fi

    mv -f "$RAW_ZIP" "$OUTPUT_PATH"
    rm -rf "$STAGE_DIR"
    ok "已按 Payload/ 结构打包"
fi

# ---------- [6/6] 校验产物 ----------

step 6 "校验产物"

[ -f "$OUTPUT_PATH" ] || die "未生成 IPA：${OUTPUT_PATH}"

SIZE_BYTES="$(wc -c < "$OUTPUT_PATH" | tr -d ' ')"
SIZE_MB="$(awk -v bytes="$SIZE_BYTES" 'BEGIN { printf "%.1f", bytes / 1048576 }')"
SIZE_HUMAN="$(du -h "$OUTPUT_PATH" | awk '{ print $1 }')"

if command -v unzip >/dev/null 2>&1; then
    if unzip -l "$OUTPUT_PATH" 2>/dev/null | grep -q "Payload/${APP_NAME}.app/Info.plist"; then
        ok "包结构校验通过：Payload/${APP_NAME}.app/Info.plist 存在"
    else
        warn "包内未检出 Payload/${APP_NAME}.app/Info.plist，请手动 unzip -l 检查"
    fi
fi

printf '\n%s────────────────────────────────────────────%s\n' "$C_DIM" "$C_OFF"
printf '  %s产物%s  %s\n' "$C_BOLD" "$C_OFF" "$OUTPUT_PATH"
printf '  %s大小%s  %s（%s MB / %s 字节）\n' "$C_BOLD" "$C_OFF" "$SIZE_HUMAN" "$SIZE_MB" "$SIZE_BYTES"
printf '  %s配置%s  %s / %s\n' "$C_BOLD" "$C_OFF" "$CONFIGURATION" "$SIGN_MODE"
printf '%s────────────────────────────────────────────%s\n' "$C_DIM" "$C_OFF"

if [ "$SIGN_MODE" = "signed" ]; then
    cat <<EOF

下一步（任选其一）：
  1) 图形界面：Xcode → Window → Devices and Simulators → 选中 iPhone
     → 「+」选择上面的 .ipa
  2) 命令行：
       xcrun devicectl device install app --device <UDID> <解包后的 .app>
     （devicectl 需要 Xcode 15+，且设备已信任本机）
  3) 分发：把 .ipa 拖进 Apple Configurator 或用 Transporter 上传 TestFlight

提示：development 描述文件只允许已注册到该 Team 的设备安装。
      新增设备后需要在 developer.apple.com 重新生成描述文件再打包。
EOF
else
    cat <<EOF

这是一个${C_BOLD}未签名${C_OFF} IPA，不能直接装到 iPhone。下一步：
  1) 用 Sideloadly（Windows / macOS）打开上面的 .ipa，
     填你自己的 Apple ID，它会用你的免费证书重签后安装
  2) 或用 AltStore / SideStore（需要电脑跑 AltServer）
  3) 免费 Apple ID 签出来的 App 7 天过期，过期后重复步骤 1 即可

注意：免费个人团队通常不授予 App Groups 能力，
      若重签时报 “Provisioning profile doesn't support App Groups”，
      说明屏幕共享扩展装不上（主 App 界面仍可安装验证）。
      要看完整屏幕共享，请使用付费开发者账号。
EOF
fi

printf '\n%s构建完成。%s\n' "$C_OK" "$C_OFF"
