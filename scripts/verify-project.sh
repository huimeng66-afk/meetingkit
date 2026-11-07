#!/usr/bin/env bash
#
# verify-project.sh — 不依赖 Xcode 的工程体检脚本（Linux / macOS 均可运行）
#
# 为什么需要它：iOS 二进制只能在 macOS 上产出，但「工程配置是否正确」这件事
# 大部分可以用 Python 解析 + Swift 语法分析在 Linux 上验证完。
# 这个脚本就是 Linux 沙箱里唯一能真跑的真实验证手段。
#
# 检查项：
#   1. 必备文件存在性
#   2. 2 个 Info.plist、2 个 entitlements、3 个 Assets JSON、project.yml 可解析
#   3. 关键一致性：App Group 标识、Bundle ID 前缀、扩展 Principal Class 模块名
#   4. 全仓 Swift 文件语法检查（swiftc -parse，不做类型检查，不联网）
#   5. 打包脚本与 CI 工作流可用性（bash -n + YAML 解析）
#
# 用法：
#   ./scripts/verify-project.sh
#   MK_SWIFTC=/opt/swift/usr/bin/swiftc ./scripts/verify-project.sh
#
# 退出码：0 无 FAIL（普通模式允许 SKIP）；1 有 FAIL 或 strict 模式有 SKIP
# 兼容：macOS 自带 bash 3.2（不使用关联数组、mapfile、${var,,}）

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_ROOT" || exit 1

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

STRICT=0
case "${1:-}" in
    --strict) STRICT=1; shift ;;
    --help|-h) echo "Usage: $0 [--strict] (strict: SKIP causes failure)"; exit 0 ;;
esac
[ "$#" -eq 0 ] || { echo "Unknown argument" >&2; exit 1; }
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
skip() {
    SKIP_COUNT=$((SKIP_COUNT + 1))
    printf '  SKIP  %s\n' "$1"
}

section() {
    printf '\n%s── %s %s\n' "$C_BOLD" "$1" "$C_OFF"
}

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf '  %sPASS%s  %s\n' "$C_OK" "$C_OFF" "$1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf '  %sFAIL%s  %s\n' "$C_ERR" "$C_OFF" "$1"
    if [ "$#" -ge 2 ] && [ -n "$2" ]; then
        printf '        %s↳ %s%s\n' "$C_DIM" "$2" "$C_OFF"
    fi
}

printf '%sMeetingKit · 工程体检%s  %s(%s)%s\n' \
    "$C_BOLD" "$C_OFF" "$C_DIM" "$PROJECT_ROOT" "$C_OFF"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/meetingkit-verify.XXXXXX")" || exit 1
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------- 1. 必备文件

section "1. 必备文件"

REQUIRED_FILES=(
    "project.yml"
    "MeetingKit/Info.plist"
    "BroadcastExtension/Info.plist"
    "MeetingKit/MeetingKit.entitlements"
    "BroadcastExtension/MeetingBroadcast.entitlements"
    "BroadcastExtension/SampleHandler.swift"
    "MeetingKit/Views/MeetingRoomView.swift"
)

for rel in "${REQUIRED_FILES[@]}"; do
    if [ -f "$rel" ]; then
        pass "$rel"
    else
        fail "$rel 不存在" "工程根目录：$PROJECT_ROOT"
    fi
done

# ------------------------------------------------- 2. plist / JSON / YAML 解析

section "2. 配置解析"

if ! command -v python3 >/dev/null 2>&1; then
    fail "未找到 python3" "本脚本依赖 python3 解析 plist / JSON / YAML"
else
    PY_REPORT="${TMP_DIR}/config-report.txt"
    PY_STDERR="${TMP_DIR}/config-stderr.txt"

    python3 - "$PROJECT_ROOT" >"$PY_REPORT" 2>"$PY_STDERR" <<'PY'
# -*- coding: utf-8 -*-
"""解析工程配置并输出 PASS|消息|详情 行，供 bash 汇总。"""

import json
import os
import plistlib
import re
import sys

ROOT = sys.argv[1]

PLISTS = [
    "MeetingKit/Info.plist",
    "BroadcastExtension/Info.plist",
    "MeetingKit/MeetingKit.entitlements",
    "BroadcastExtension/MeetingBroadcast.entitlements",
]

ASSET_JSONS = [
    "MeetingKit/Resources/Assets.xcassets/Contents.json",
    "MeetingKit/Resources/Assets.xcassets/AccentColor.colorset/Contents.json",
    "MeetingKit/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json",
]


def emit(status, message, detail=""):
    """输出一行结果；详情里的换行与竖线会被压平，避免破坏 bash 的字段分割。"""
    flat = str(detail).replace("\n", " ").replace("|", "/").strip()
    sys.stdout.write("%s|%s|%s\n" % (status, message, flat))


def read_plist(rel):
    with open(os.path.join(ROOT, rel), "rb") as handle:
        return plistlib.load(handle)


def read_json(rel):
    with open(os.path.join(ROOT, rel), "r", encoding="utf-8") as handle:
        return json.load(handle)


# ---- plist / entitlements ----

loaded = {}
for rel in PLISTS:
    try:
        data = read_plist(rel)
        loaded[rel] = data
        emit("PASS", "%s 解析通过 (%d 个顶层键)" % (rel, len(data)))
    except Exception as exc:  # noqa: BLE001 - 需要把任何解析错误报给用户
        emit("FAIL", "%s 解析失败" % rel, "%s: %s" % (type(exc).__name__, exc))

# ---- Assets JSON ----

for rel in ASSET_JSONS:
    try:
        data = read_json(rel)
        emit("PASS", "%s 是合法 JSON (%d 个顶层键)" % (os.path.basename(os.path.dirname(rel)) + "/" + os.path.basename(rel), len(data)))
    except Exception as exc:  # noqa: BLE001
        emit("FAIL", "%s 不是合法 JSON" % rel, "%s: %s" % (type(exc).__name__, exc))

# ---- project.yml ----

project = None
try:
    import yaml  # 延迟导入，缺库时给出可执行的修复建议
    with open(os.path.join(ROOT, "project.yml"), "r", encoding="utf-8") as handle:
        project = yaml.safe_load(handle)
    if isinstance(project, dict) and "targets" in project:
        emit("PASS", "project.yml 解析通过 (targets: %s)" % ", ".join(sorted(project["targets"].keys())))
    else:
        emit("FAIL", "project.yml 结构异常", "缺少 targets 段")
except ImportError:
    emit("FAIL", "缺少 PyYAML，无法解析 project.yml", "pip3 install pyyaml  (macOS: brew install python && pip3 install pyyaml)")
except Exception as exc:  # noqa: BLE001
    emit("FAIL", "project.yml 解析失败", "%s: %s" % (type(exc).__name__, exc))

# ---- 关键一致性 ----

if project is None or not isinstance(project, dict):
    emit("FAIL", "跳过一致性检查", "project.yml 未能解析")
elif loaded.get("MeetingKit/Info.plist") is None:
    emit("FAIL", "跳过一致性检查", "主 App Info.plist 未能解析")
else:
    app_t = project.get("targets", {}).get("MeetingKit", {}) or {}
    ext_t = project.get("targets", {}).get("MeetingBroadcast", {}) or {}
    app_s = app_t.get("settings", {}).get("base", {}) or {}
    ext_s = ext_t.get("settings", {}).get("base", {}) or {}

    app_bundle = str(app_s.get("PRODUCT_BUNDLE_IDENTIFIER", ""))
    ext_bundle = str(ext_s.get("PRODUCT_BUNDLE_IDENTIFIER", ""))
    ext_product = str(ext_s.get("PRODUCT_NAME", ""))

    for label, settings, rel in (("主 App", app_s, "MeetingKit/Info.plist"),
                                  ("扩展", ext_s, "BroadcastExtension/Info.plist")):
        configured = str(settings.get("PRODUCT_BUNDLE_IDENTIFIER", ""))
        info_id = (loaded.get(rel) or {}).get("CFBundleIdentifier")
        if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", configured):
            emit("FAIL", label + " PRODUCT_BUNDLE_IDENTIFIER 无效或未解析")
        elif info_id not in (configured, "$(PRODUCT_BUNDLE_IDENTIFIER)", "${PRODUCT_BUNDLE_IDENTIFIER}"):
            emit("FAIL", label + " Info.plist 与 PRODUCT_BUNDLE_IDENTIFIER 不一致")
        else:
            emit("PASS", label + " Info.plist Bundle ID 与实际工程配置一致")

    # 1) AppGroupConfig 里的三个常量
    swift_rel = "Shared/AppGroupConfig.swift"
    swift_text = ""
    try:
        with open(os.path.join(ROOT, swift_rel), "r", encoding="utf-8") as handle:
            swift_text = handle.read()
        emit("PASS", "%s 可读取 (%d 行)" % (swift_rel, swift_text.count("\n") + 1))
    except Exception as exc:  # noqa: BLE001
        emit("FAIL", "%s 读取失败" % swift_rel, str(exc))

    values = {}
    for name in ("identifier", "bundleIdentifier", "broadcastExtensionBundleIdentifier"):
        match = re.search(r'static\s+let\s+' + name + r'\s*=\s*"([^"]+)"', swift_text)
        if match:
            values[name] = match.group(1)
        elif name == "identifier":
            # identifier 是运行时探测出来的（free 账号没有 App Groups 时会降级），
            # 源码里写成 `static let identifier: String = resolveIdentifier()`，
            # 字面量只存在于 preferredIdentifier。这里回退取它做校验，
            # 否则每次都会误报 FAIL。
            fallback = re.search(r'static\s+let\s+preferredIdentifier\s*=\s*"([^"]+)"', swift_text)
            if fallback:
                values[name] = fallback.group(1)
                emit("PASS", "AppGroupConfig.identifier 为运行时解析，按 preferredIdentifier 校验 (%s)" % fallback.group(1))
            else:
                emit("FAIL", "AppGroupConfig.identifier 与 preferredIdentifier 均未找到", "期望 static let preferredIdentifier = \"group.xxx\"")
        elif name == "bundleIdentifier" and re.search(r'static\s+let\s+bundleIdentifier\s*:\s*String\s*=\s*Bundle\.main\.bundleIdentifier', swift_text):
            emit("PASS", "主 App Bundle ID 来自运行时，校验工程与 Info.plist")
        elif name == "broadcastExtensionBundleIdentifier" and re.search(r'static\s+let\s+broadcastExtensionBundleIdentifier\s*:\s*String\s*=\s*resolveExtensionBundleIdentifier\(\)', swift_text):
            emit("PASS", "扩展 Bundle ID 来自内嵌 bundle，校验工程与 Info.plist")
        else:
            emit("FAIL", "AppGroupConfig.%s 未找到或无法识别" % name)

    group_id = values.get("identifier", "")

    # 2) App Group 必须同时出现在两份 entitlements
    if group_id:
        ents = [
            ("主 App", "MeetingKit/MeetingKit.entitlements", loaded.get("MeetingKit/MeetingKit.entitlements")),
            ("扩展", "BroadcastExtension/MeetingBroadcast.entitlements", loaded.get("BroadcastExtension/MeetingBroadcast.entitlements")),
        ]
        for label, rel, data in ents:
            if data is None:
                emit("FAIL", "%s entitlements 未能解析，无法校验 App Group" % label, rel)
                continue
            groups = data.get("com.apple.security.application-groups", [])
            if not isinstance(groups, list):
                groups = []
            if group_id in groups:
                emit("PASS", "%s entitlements 含 App Group %s" % (label, group_id))
            else:
                emit("FAIL", "%s entitlements 缺少 App Group %s" % (label, group_id), "%s 实际值：%s" % (rel, groups))

        # 两份 entitlements 的 App Group 集合必须一致
        main_groups = loaded.get("MeetingKit/MeetingKit.entitlements", {}).get("com.apple.security.application-groups", [])
        ext_groups = loaded.get("BroadcastExtension/MeetingBroadcast.entitlements", {}).get("com.apple.security.application-groups", [])
        if sorted(main_groups) == sorted(ext_groups):
            emit("PASS", "两份 entitlements 的 App Group 列表完全一致")
        else:
            emit("FAIL", "两份 entitlements 的 App Group 列表不一致", "主 App=%s 扩展=%s" % (main_groups, ext_groups))

    # 3) Swift 常量与 project.yml 的 Bundle ID 对齐
    if values.get("bundleIdentifier"):
        if values["bundleIdentifier"] == app_bundle:
            emit("PASS", "AppGroupConfig.bundleIdentifier == 主 App PRODUCT_BUNDLE_IDENTIFIER (%s)" % app_bundle)
        else:
            emit("FAIL", "AppGroupConfig.bundleIdentifier 与 project.yml 不一致",
                 "Swift=%s project.yml=%s" % (values["bundleIdentifier"], app_bundle))

    if values.get("broadcastExtensionBundleIdentifier"):
        if values["broadcastExtensionBundleIdentifier"] == ext_bundle:
            emit("PASS", "AppGroupConfig.broadcastExtensionBundleIdentifier == 扩展 Bundle ID (%s)" % ext_bundle)
        else:
            emit("FAIL", "AppGroupConfig.broadcastExtensionBundleIdentifier 与 project.yml 不一致",
                 "Swift=%s project.yml=%s" % (values["broadcastExtensionBundleIdentifier"], ext_bundle))

    # 4) 扩展 Bundle ID 必须以主 App Bundle ID 为前缀（否则 PlugIns 内嵌校验会失败）
    if app_bundle and ext_bundle:
        if ext_bundle.startswith(app_bundle + "."):
            emit("PASS", "扩展 Bundle ID 以主 App 为前缀 (%s ← %s)" % (ext_bundle, app_bundle))
        else:
            emit("FAIL", "扩展 Bundle ID 不以主 App Bundle ID 为前缀",
                 "主 App=%s 扩展=%s，应为 %s.<后缀>" % (app_bundle, ext_bundle, app_bundle))

    # 5) NSExtensionPrincipalClass 的模块名必须等于扩展 PRODUCT_NAME
    ext_info = loaded.get("BroadcastExtension/Info.plist") or {}
    extension_dict = ext_info.get("NSExtension", {}) if isinstance(ext_info.get("NSExtension"), dict) else {}
    principal = str(extension_dict.get("NSExtensionPrincipalClass", ""))
    if principal:
        module_token = principal.rsplit(".", 1)[0] if "." in principal else ""
        if module_token == "$(PRODUCT_MODULE_NAME)":
            # Xcode 默认：PRODUCT_MODULE_NAME = PRODUCT_NAME，非字母数字替换为 _
            expected = re.sub(r"[^0-9A-Za-z]", "_", ext_product)
        else:
            expected = module_token
        if expected and expected == re.sub(r"[^0-9A-Za-z]", "_", ext_product):
            emit("PASS", "NSExtensionPrincipalClass 模块名与扩展 PRODUCT_NAME 一致 (%s)" % expected)
        else:
            emit("FAIL", "NSExtensionPrincipalClass 模块名与扩展 PRODUCT_NAME 不一致",
                 "PrincipalClass=%s 期望模块=%s PRODUCT_NAME=%s" % (principal, expected, ext_product))
    else:
        emit("FAIL", "扩展 Info.plist 缺少 NSExtensionPrincipalClass", "系统将无法实例化 SampleHandler")

    # 6) 广播扩展的上传点标识
    point = str(extension_dict.get("NSExtensionPointIdentifier", ""))
    if point == "com.apple.broadcast-services-upload":
        emit("PASS", "扩展 NSExtensionPointIdentifier 为 ReplayKit 上传点")
    else:
        emit("FAIL", "扩展 NSExtensionPointIdentifier 不是 com.apple.broadcast-services-upload", "实际：%s" % (point or "(空)"))

    # 7) 主 App 必须声明图标与照片/麦克风等用途描述（否则安装后崩溃或提审被拒）
    app_info = loaded.get("MeetingKit/Info.plist") or {}
    usage_keys = ["NSCameraUsageDescription", "NSMicrophoneUsageDescription"]
    missing_usage = [key for key in usage_keys if not app_info.get(key)]
    if missing_usage:
        emit("FAIL", "主 App Info.plist 缺少用途描述", ", ".join(missing_usage))
    else:
        emit("PASS", "主 App 已声明相机与麦克风用途描述")

    if app_info.get("CFBundlePackageType") == "APPL":
        emit("PASS", "主 App CFBundlePackageType == APPL")
    else:
        emit("FAIL", "主 App CFBundlePackageType 不是 APPL", "实际：%s" % app_info.get("CFBundlePackageType"))

    if ext_info.get("CFBundlePackageType") == "XPC!":
        emit("PASS", "扩展 CFBundlePackageType == XPC!")
    else:
        emit("FAIL", "扩展 CFBundlePackageType 不是 XPC!", "实际：%s" % ext_info.get("CFBundlePackageType"))

    # 8) 扩展被内嵌到 App 的 PlugIns 里（embed: true），并声明 AppIcon
    deps = app_t.get("dependencies", []) or []
    embedded = False
    for dep in deps:
        if isinstance(dep, dict) and dep.get("target") == "MeetingBroadcast" and dep.get("embed") is True:
            embedded = True
    if embedded:
        emit("PASS", "主 App 以 embed: true 内嵌广播扩展")
    else:
        emit("FAIL", "主 App 未以 embed: true 内嵌广播扩展", "系统录屏列表不会出现 MeetingKit 屏幕共享")

    if str(app_s.get("ASSETCATALOG_COMPILER_APPICON_NAME", "")) == "AppIcon":
        emit("PASS", "主 App 已指定 ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon")
    else:
        emit("FAIL", "主 App 未指定 AppIcon 资源名", "安装后图标为空白")

    icon_rel = "MeetingKit/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
    if os.path.isfile(os.path.join(ROOT, icon_rel)):
        emit("PASS", "AppIcon-1024.png 存在 (%d 字节)" % os.path.getsize(os.path.join(ROOT, icon_rel)))
    else:
        emit("FAIL", "AppIcon-1024.png 缺失", icon_rel)
PY

    if [ -s "$PY_STDERR" ]; then
        fail "配置解析脚本输出错误信息" "$(head -n 3 "$PY_STDERR" | tr '\n' ' ')"
    fi

    if [ -s "$PY_REPORT" ]; then
        while IFS='|' read -r status message detail; do
            if [ "$status" = "PASS" ]; then
                pass "$message"
            elif [ "$status" = "FAIL" ]; then
                fail "$message" "$detail"
            fi
        done <"$PY_REPORT"
    else
        fail "配置解析没有产生任何结果" "Python 脚本可能提前退出，见上方错误信息"
    fi
fi

# ---------------------------------------------------------------- 3. Swift 语法

section "3. Swift 语法检查"

MK_SWIFTC="${MK_SWIFTC:-}"
if [ -z "$MK_SWIFTC" ]; then
    if [ -x "/opt/swift/usr/bin/swiftc" ]; then
        MK_SWIFTC="/opt/swift/usr/bin/swiftc"
    elif command -v swiftc >/dev/null 2>&1; then
        MK_SWIFTC="$(command -v swiftc)"
    fi
fi

if ! find "$PROJECT_ROOT" -name '*.swift' -not -path '*/.build/*' -not -path '*/build/*' -print0 >"${TMP_DIR}/swift-files"; then
    fail "Swift 文件枚举失败"
fi
SWIFT_FILES=()
while IFS= read -r -d '' swift_path; do
    SWIFT_FILES+=("$swift_path")
done <"${TMP_DIR}/swift-files"

if [ "${#SWIFT_FILES[@]}" -eq 0 ]; then
    fail "没有找到任何 .swift 文件" "$PROJECT_ROOT"
elif [ -z "$MK_SWIFTC" ]; then
    skip "未找到 swiftc，未执行语法检查；设置 MK_SWIFTC=/path/to/swiftc 后重试"
else
    SWIFT_ERR="${TMP_DIR}/swiftc.log"
    if "$MK_SWIFTC" -parse "${SWIFT_FILES[@]}" >/dev/null 2>"$SWIFT_ERR"; then
        pass "swiftc -parse 通过（${#SWIFT_FILES[@]} 个文件）"
    else
        fail "swiftc -parse 失败（${#SWIFT_FILES[@]} 个文件）" "$(grep -m 3 'error:' "$SWIFT_ERR" | tr '\n' ' ')"
    fi
    info_version="$("$MK_SWIFTC" --version 2>/dev/null | head -n 1)"
    printf '        %s%s%s\n' "$C_DIM" "$info_version" "$C_OFF"
fi

# --------------------------------------------------- 4. 打包脚本与 CI 工作流

section "4. 打包脚本与 CI 工作流"

SCRIPTS=(
    "scripts/build-ipa.sh"
    "scripts/build-ipa-unsigned.sh"
    "scripts/verify-project.sh"
    "scripts/sign-ipa.sh"
)

for rel in "${SCRIPTS[@]}"; do
    if [ ! -f "$rel" ]; then
        fail "$rel 不存在"
        continue
    fi
    if bash -n "$rel" 2>"${TMP_DIR}/bash-n.log"; then
        pass "$rel 语法检查通过"
    else
        fail "$rel 语法错误" "$(head -n 2 "${TMP_DIR}/bash-n.log" | tr '\n' ' ')"
    fi
done

WORKFLOW=".github/workflows/ios-build.yml"
if [ ! -f "$WORKFLOW" ]; then
    fail "$WORKFLOW 不存在"
elif python3 - "$PROJECT_ROOT" "$WORKFLOW" >"${TMP_DIR}/wf.json" 2>"${TMP_DIR}/wf.err" <<'PY'
# -*- coding: utf-8 -*-
"""轻量校验工作流：能被 YAML 解析，且声明了 macOS runner 与 artifact 上传。"""

import sys

import yaml

root, rel = sys.argv[1], sys.argv[2]
with open("%s/%s" % (root, rel), "r", encoding="utf-8") as handle:
    data = yaml.safe_load(handle)

problems = []
if not isinstance(data, dict):
    problems.append("顶层不是映射")
else:
    # YAML 1.1 会把裸 on 解析成布尔 True，两种键都接受
    if "on" not in data and True not in data:
        problems.append("缺少 on 触发条件")
    jobs = data.get("jobs") or {}
    if not jobs:
        problems.append("缺少 jobs")
    else:
        for name, job in jobs.items():
            runs_on = str((job or {}).get("runs-on", ""))
            if "macos" not in runs_on:
                problems.append("job %s 没有跑在 macOS runner 上" % name)
            steps = (job or {}).get("steps") or []
            text = yaml.safe_dump(steps, allow_unicode=True)
            if "upload-artifact" not in text:
                problems.append("job %s 没有 upload-artifact 步骤" % name)

if problems:
    sys.stderr.write("; ".join(problems))
    sys.exit(1)
PY
then
    pass "$WORKFLOW 是合法 YAML，且含 macOS runner + artifact 上传"
else
    fail "$WORKFLOW 校验未通过" "$(head -c 300 "${TMP_DIR}/wf.err")"
fi

# ---------------------------------------------------------------------- 汇总

printf '\n%s────────────────────────────────────────────%s\n' "$C_DIM" "$C_OFF"
printf 'PASS: %d  FAIL: %d  SKIP: %d\n' "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
if [ "$FAIL_COUNT" -eq 0 ] && [ "$SKIP_COUNT" -eq 0 ]; then
    printf '%s工程配置自洽，可以交给 macOS 出包。%s\n' "$C_DIM" "$C_OFF"
elif [ "$FAIL_COUNT" -eq 0 ]; then
    printf '检查不完整：存在 SKIP，未验证 Swift 语法。\n'
else
    printf '%s有 %d 项检查未通过，先修配置再出包。%s\n' "$C_ERR" "$FAIL_COUNT" "$C_OFF"
fi
printf '%s────────────────────────────────────────────%s\n' "$C_DIM" "$C_OFF"

if [ "$FAIL_COUNT" -gt 0 ] || { [ "$STRICT" -eq 1 ] && [ "$SKIP_COUNT" -gt 0 ]; }; then
    exit 1
fi
exit 0
