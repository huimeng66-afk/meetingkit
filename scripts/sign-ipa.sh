#!/usr/bin/env bash
#
# sign-ipa.sh — 用一张开发证书给「未签名 IPA」签名，并保证广播扩展也拿到描述文件。
#
# ── 为什么不能直接 `zsign -m profile in.ipa` ──────────────────────────
# zsign 只给**主 bundle** 写 embedded.mobileprovision，PlugIns/*.appex 不写。
# 而本项目的跨进程共享链路是这么定位 App Group 的（见 Shared/AppGroupConfig.swift）：
#   启动 → 读自己 bundle 里的 embedded.mobileprovision → 扫出 profile 授权的 group 名
#        → 逐个 containerURL 实测 → 取第一个可用的
# 主 App 有 profile，能扫到 `group.e2904eee920f2ee6.1`；
# 扩展没有 profile，只剩工程里写死的 `group.com.tianqiong.meetingkit`，
# 而这个名字证书并没授权 → containerURL 返回 nil → 扩展写帧写不进去。
# 结果：用户点了共享、扩展确实在录，主 App 一帧都收不到，对端永远黑屏。
#
# 所以流程必须是：**先解包 → 把 profile 复制进 App 与每个 .appex → 再对 .app 目录签名**。
# 顺序反了不行：签名后再往 bundle 里加文件会破坏 CodeResources 封印，安装直接失败。
#
# 用法：
#   ./scripts/sign-ipa.sh \
#       --ipa build/MeetingKit-unsigned.ipa \
#       --p12 /path/cert.p12 --password 1 \
#       --profile /path/profile.mobileprovision \
#       --output build/MeetingKit-signed.ipa
#
# 依赖：zsign（https://github.com/zhlynn/zsign）、unzip、python3
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

IPA=""
P12=""
PASSWORD=""
PROFILE=""
OUTPUT=""
ZSIGN="${ZSIGN:-zsign}"

while [ $# -gt 0 ]; do
    case "$1" in
        --ipa)      IPA="$2"; shift 2 ;;
        --p12)      P12="$2"; shift 2 ;;
        --password) PASSWORD="$2"; shift 2 ;;
        --profile)  PROFILE="$2"; shift 2 ;;
        --output)   OUTPUT="$2"; shift 2 ;;
        --zsign)    ZSIGN="$2"; shift 2 ;;
        -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 1 ;;
    esac
done

for pair in "ipa:${IPA}" "p12:${P12}" "profile:${PROFILE}" "output:${OUTPUT}"; do
    key="${pair%%:*}"; value="${pair#*:}"
    if [ -z "${value}" ]; then
        echo "缺少参数 --${key}" >&2; exit 1
    fi
done
[ -f "${IPA}" ] || { echo "找不到 IPA: ${IPA}" >&2; exit 1; }
[ -f "${P12}" ] || { echo "找不到证书: ${P12}" >&2; exit 1; }
[ -f "${PROFILE}" ] || { echo "找不到描述文件: ${PROFILE}" >&2; exit 1; }
command -v "${ZSIGN}" >/dev/null 2>&1 || { echo "找不到 zsign: ${ZSIGN}" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tqsign.XXXXXX")"
cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT

echo "▸ 解包 $(basename "${IPA}")"
unzip -q "${IPA}" -d "${WORK}/src"

APP_PATH="$(find "${WORK}/src/Payload" -maxdepth 1 -name '*.app' -type d | head -1)"
[ -n "${APP_PATH}" ] || { echo "Payload 里没有 .app" >&2; exit 1; }
APP_NAME="$(basename "${APP_PATH}" .app)"
echo "  主 App: ${APP_NAME}.app"

# 1) 主 App + 每一个扩展都放同一份 profile
cp "${PROFILE}" "${APP_PATH}/embedded.mobileprovision"
echo "  ✓ ${APP_NAME}.app/embedded.mobileprovision"

if [ -d "${APP_PATH}/PlugIns" ]; then
    while IFS= read -r appex; do
        [ -n "${appex}" ] || continue
        cp "${PROFILE}" "${appex}/embedded.mobileprovision"
        echo "  ✓ $(basename "${appex}")/embedded.mobileprovision"
    done < <(find "${APP_PATH}/PlugIns" -maxdepth 1 -name '*.appex' -type d)
fi

# 2) 对 .app 目录签名（zsign 会递归处理 Frameworks 与 PlugIns）
echo "▸ 签名"
"${ZSIGN}" \
    -k "${P12}" \
    -p "${PASSWORD}" \
    -m "${PROFILE}" \
    -o "${OUTPUT}" \
    "${APP_PATH}" \
    -z 9 | sed 's/^/  /'

[ -f "${OUTPUT}" ] || { echo "签名失败：没有产物" >&2; exit 1; }

# 3) 校验：profile 是否双端都在、bundle id 是否被意外改写
echo "▸ 校验产物"
VERIFY="$(mktemp -d "${TMPDIR:-/tmp}/tqverify.XXXXXX")"
unzip -q "${OUTPUT}" -d "${VERIFY}"

python3 - "${VERIFY}" <<'PY'
import os, plistlib, sys

root = sys.argv[1]
payload = os.path.join(root, 'Payload')
app = next(os.path.join(payload, d) for d in os.listdir(payload) if d.endswith('.app'))

problems = []

if not os.path.exists(os.path.join(app, 'embedded.mobileprovision')):
    problems.append('主 App 缺 embedded.mobileprovision')

plugins = os.path.join(app, 'PlugIns')
if os.path.isdir(plugins):
    for name in os.listdir(plugins):
        if not name.endswith('.appex'):
            continue
        prof = os.path.join(plugins, name, 'embedded.mobileprovision')
        if not os.path.exists(prof):
            problems.append(f'{name} 缺 embedded.mobileprovision')

info = plistlib.load(open(os.path.join(app, 'Info.plist'), 'rb'))
bundle_id = info.get('CFBundleIdentifier', '')
if not bundle_id or bundle_id.startswith('com.example'):
    problems.append(f'Bundle ID 异常: {bundle_id}')

print(f"  Bundle ID : {bundle_id}")
print(f"  版本      : {info.get('CFBundleShortVersionString')} ({info.get('CFBundleVersion')})")
print(f"  最低系统  : {info.get('MinimumOSVersion')}")

if plugins and os.path.isdir(plugins):
    for name in sorted(os.listdir(plugins)):
        if name.endswith('.appex'):
            print(f"  扩展      : {name}")

if problems:
    print('\n'.join('  ✗ ' + p for p in problems))
    sys.exit(1)
print('  ✓ 双端描述文件齐全')
PY

rm -rf "${VERIFY}"

echo "▸ 完成：${OUTPUT} ($(du -h "${OUTPUT}" | cut -f1))"
