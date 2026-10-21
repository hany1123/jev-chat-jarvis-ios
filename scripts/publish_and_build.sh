#!/usr/bin/env bash
#
# 一键完成：Fork → 推送 → 触发 CI → 下载 IPA
#
# 前置：已完成 gh auth login（设备码或 PAT 均可）
#
# 用法:
#   bash scripts/publish_and_build.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

UPSTREAM="jev-chat/jev-chat-jarvis-ios"
BRANCH="feat/trollstore-ipa"

log() { printf '\033[1;36m[step]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 0. 检查登录 ----------
gh auth status >/dev/null 2>&1 || die "未登录 GitHub。请先执行：
  gh auth login --hostname github.com --git-protocol https --web
或
  echo \$TOKEN | gh auth login --with-token"

LOGIN_USER="$(gh api user --jq .login 2>/dev/null)" || die "无法读取 GitHub 用户名"
log "当前 GitHub 账号: $LOGIN_USER"

# ---------- 1. Fork ----------
FORK_FULL="$LOGIN_USER/jev-chat-jarvis-ios"
if gh repo view "$FORK_FULL" >/dev/null 2>&1; then
  log "Fork 已存在: $FORK_FULL"
else
  log "创建 Fork: $UPSTREAM -> $FORK_FULL"
  # --clone=false 只建仓库不克隆；--remote 与仓库参数互斥，故不传
  gh repo fork "$UPSTREAM" --clone=false
  # 等 fork 落库
  for i in $(seq 1 10); do
    gh repo view "$FORK_FULL" >/dev/null 2>&1 && break
    sleep 3
  done
  gh repo view "$FORK_FULL" >/dev/null 2>&1 || die "Fork 创建失败"
  log "Fork 完成: $FORK_FULL"
fi

# ---------- 2. 配置 remote 并推送 ----------
if git remote get-url fork >/dev/null 2>&1; then
  git remote set-url fork "https://github.com/$FORK_FULL.git"
else
  git remote add fork "https://github.com/$FORK_FULL.git"
fi

log "推送分支 $BRANCH 到 fork"
git push -f fork "HEAD:refs/heads/$BRANCH"

# Actions 只在默认分支上展示 workflow_dispatch，
# 所以还要把 fork 的默认分支同步到含工作流的版本。
DEFAULT_BRANCH="$(gh repo view "$FORK_FULL" --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null || echo main)"
log "fork 默认分支: $DEFAULT_BRANCH"

if [ "$DEFAULT_BRANCH" != "$BRANCH" ]; then
  log "将 $BRANCH 强制推为默认分支 $DEFAULT_BRANCH（确保 Actions 页面出现工作流）"
  git push -f fork "HEAD:refs/heads/$DEFAULT_BRANCH"
fi

# ---------- 3. 触发工作流 ----------
log "触发 workflow_dispatch"
sleep 3
gh workflow run build-trollstore-ipa.yml \
  --repo "$FORK_FULL" \
  --ref "$DEFAULT_BRANCH" \
  -f configuration=Release || die "触发工作流失败（若刚推完可稍等几秒重试）"

# ---------- 4. 等待并下载 ----------
log "等待构建完成（macOS runner 约 8-15 分钟）…"
RUN_ID=""
for i in $(seq 1 60); do
  sleep 20
  RUN_ID="$(gh run list --repo "$FORK_FULL" --workflow build-trollstore-ipa.yml \
    --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null || echo "")"
  if [ -n "$RUN_ID" ]; then
    STATUS="$(gh run view "$RUN_ID" --repo "$FORK_FULL" --json status --jq .status 2>/dev/null || echo "")"
    CONCL="$(gh run view "$RUN_ID" --repo "$FORK_FULL" --json conclusion --jq .conclusion 2>/dev/null || echo "")"
    printf '\r  运行 #%s  状态=%s 结论=%s   ' "$RUN_ID" "$STATUS" "$CONCL"
    if [ "$STATUS" = "completed" ]; then
      echo
      if [ "$CONCL" != "success" ]; then
        gh run view "$RUN_ID" --repo "$FORK_FULL" --log-failed || true
        die "构建失败，日志见上"
      fi
      break
    fi
  fi
done

[ -n "$RUN_ID" ] || die "超时：未取到运行 ID"

log "下载产物"
rm -rf "$ROOT/dist"
mkdir -p "$ROOT/dist"
gh run download "$RUN_ID" --repo "$FORK_FULL" --dir "$ROOT/dist" || die "下载失败"

# gh run download 会把 artifact 按名字建一层子目录，IPA 在其中。
# 这里向上找一层，兼容两种布局。
IPA="$(find "$ROOT/dist" -name "JevJarvis-trollstore.ipa" -type f | head -1)"
[ -n "$IPA" ] || die "产物中未找到 IPA，目录内容：$(ls -R "$ROOT/dist")"

# 统一平铺到 dist/ 根目录，方便取用
if [ "$(dirname "$IPA")" != "$ROOT/dist" ]; then
  mv "$(dirname "$IPA")"/* "$ROOT/dist"/ 2>/dev/null || true
  rmdir "$(dirname "$IPA")" 2>/dev/null || true
  IPA="$ROOT/dist/JevJarvis-trollstore.ipa"
fi

echo
log "完成 ✅"
echo "  IPA: $IPA"
[ -f "$ROOT/dist/SHA256SUMS.txt" ] && { echo "  校验:"; cat "$ROOT/dist/SHA256SUMS.txt"; }
echo
echo "  下一步：把 IPA 传到 iPhone，用 TrollStore 打开安装。"
echo "  装完记得开「允许完全访问」，否则键盘读不到配置。"
