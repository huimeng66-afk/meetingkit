#!/usr/bin/env bash
# sign-ipa.sh — legacy single-main-bundle signing entry.
# Extensions require independently audited profiles and a verified signing workflow.
# This entry refuses extension IPAs; use audit-signing.py to review authorization.
# No recursive zsign options are changed or assumed verified here.

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

# Fail closed: never distribute one profile to nested app/extension bundles.
if find "${APP_PATH}" -mindepth 1 -type d \( -name '*.appex' -o -name '*.app' \) | grep -q .; then
    echo "拒绝签名：内嵌 bundle 必须分别审计 profile；当前递归签名流程未经核验。" >&2
    exit 1
fi
python3 - "${APP_PATH}" "${PROFILE}" "${WORK}/audit.json" "${PROJECT_ROOT}" <<'PY'
import json, plistlib, sys
from pathlib import Path
app, profile, out, root = map(Path, sys.argv[1:])
info = plistlib.loads((app / 'Info.plist').read_bytes())
Path(out).write_text(json.dumps([dict(bundle_id=info['CFBundleIdentifier'],
    profile=str(profile.resolve()), info=str(app / 'Info.plist'),
    entitlements=str(root / 'MeetingKit/MeetingKit.entitlements'))]))
PY
python3 "${SCRIPT_DIR}/audit-signing.py" --manifest "${WORK}/audit.json"
cp "${PROFILE}" "${APP_PATH}/embedded.mobileprovision"

# 2) Existing zsign invocation; recursive behavior is not validated by this script.
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
VERIFY="${WORK}/verify"
mkdir -p "${VERIFY}"
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
