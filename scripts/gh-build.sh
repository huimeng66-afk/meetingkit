#!/usr/bin/env bash
#
# gh-build.sh — 不装 Xcode，也能出一条 IPA
#
# 做的事：把当前工程推到一个私有 GitHub 仓库 → 触发 macOS runner →
#        等构建结束 → 把 artifact 里的 IPA 下载到 build/。
#
# 依赖：git、gh（https://cli.github.com），并已 `gh auth login`
# 用法：
#   ./scripts/gh-build.sh                 # 默认仓库名 meetingkit-<时间戳>
#   ./scripts/gh-build.sh my-repo         # 指定仓库名
#   ./scripts/gh-build.sh my-repo Release # 指定配置
#
# 说明：产物是**未签名** IPA，安装前必须用 Sideloadly / AltStore 以你自己的
#      Apple ID 重签；免费账号 7 天过期。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

REPO="${1:-meetingkit-$(date +%Y%m%d-%H%M)}"
CONFIG="${2:-Release}"
WORKFLOW="iOS Build (unsigned IPA)"

command -v gh >/dev/null 2>&1 || { echo "缺少 gh：https://cli.github.com"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "缺少 git"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "请先运行：gh auth login"; exit 1; }

if [ ! -d .git ]; then
  echo "==> 初始化仓库"
  git init -q
  git add -A
  git -c user.email="dev@local" -c user.name="MeetingKit" commit -qm "MeetingKit build ${REPO}"
fi

if ! gh repo view "$REPO" >/dev/null 2>&1; then
  echo "==> 创建私有仓库 $REPO"
  gh repo create "$REPO" --private --source=. --remote=origin --push
else
  echo "==> 推送到已有仓库 $REPO"
  git remote get-url origin >/dev/null 2>&1 || gh repo set-default "$REPO"
  git push -u origin HEAD
fi

echo "==> 触发构建（$CONFIG）"
gh workflow run "$WORKFLOW" -f configuration="$CONFIG" 2>/dev/null || \
  gh workflow run ios-build.yml -f configuration="$CONFIG"

sleep 6
RUN_ID="$(gh run list --workflow="$WORKFLOW" --limit 1 --json databaseId --jq '.[0].databaseId')"
[ -n "$RUN_ID" ] || { echo "没找到运行记录，请到仓库 Actions 页面查看"; exit 1; }

echo "==> 等待运行 $RUN_ID（约 6~8 分钟）"
gh run watch "$RUN_ID" --exit-status || { echo "构建失败：gh run view $RUN_ID --log-failed"; exit 1; }

rm -rf build/artifact && mkdir -p build/artifact
gh run download "$RUN_ID" -n MeetingKit-unsigned-ipa -D build/artifact

IPA="$(find build/artifact -name '*.ipa' | head -1)"
[ -n "$IPA" ] || { echo "artifact 里没有 IPA"; exit 1; }
cp "$IPA" "build/$(basename "$IPA")"
echo "==> 完成：build/$(basename "$IPA")"
echo "    安装：Sideloadly 拖入 → 填 Apple ID → Start（免费账号 7 天有效）"
