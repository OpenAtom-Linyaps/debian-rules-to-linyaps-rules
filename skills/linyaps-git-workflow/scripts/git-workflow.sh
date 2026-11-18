#!/usr/bin/env bash
# linyaps-git-workflow: git-workflow.sh
#
# 统一 Git 工作流入口脚本，两种 action：
#   init_repo       — Git 仓库克隆 + 推送权限验证
#   commit_and_push — 清理工程、暂存、动态 commit message、推送
#
# 使用方式：
#   bash git-workflow.sh init_repo --projects_repo=<url> --projects_root=<path>
#   bash git-workflow.sh commit_and_push --projects_root=<path> [--data-dir=<path>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

ACTION="${1:-}"

clean_project_cache() {
  # $1: 工程目录；调用配套缓存清理脚本
  local dir="$1"
  if [[ -f "$SCRIPT_DIR/clean_project_cache.sh" ]]; then
    bash "$SCRIPT_DIR/clean_project_cache.sh" "$dir" || true
  else
    echo "警告: 未找到 clean_project_cache.sh，跳过缓存清理: $dir" >&2
  fi
}

pre_commit_guard() {
  # $1: 工程/仓库目录；命中缓存模式即退出码 1
  local dir="$1"
  if [[ -f "$SCRIPT_DIR/pre-commit-guard.sh" ]]; then
    bash "$SCRIPT_DIR/pre-commit-guard.sh" "$dir" || return $?
  else
    echo "警告: 未找到 pre-commit-guard.sh，跳过提交守卫" >&2
  fi
}
shift || true

# 参数
PROJECTS_REPO=""
PROJECTS_ROOT=""
DATA_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --projects_repo=*) PROJECTS_REPO="${1#*=}" ;;
    --projects_root=*) PROJECTS_ROOT="${1#*=}" ;;
    --data-dir=*)      DATA_DIR="${1#*=}" ;;
    *)
      echo "未知参数: $1" >&2
      exit 1
      ;;
  esac
  shift
done

output_json() {
  echo "$1"
}

# ---- init_repo ----
if [[ "$ACTION" == "init_repo" ]]; then
  if [[ -z "$PROJECTS_REPO" ]]; then
    echo '{"status":"blocked","error":"git_repo_not_configured"}'
    exit 0
  fi
  if [[ -z "$PROJECTS_ROOT" ]]; then
    PROJECTS_ROOT="./projects"
  fi

  # git clone
  CLONE_OUTPUT=$(git clone "$PROJECTS_REPO" "$PROJECTS_ROOT" 2>&1) || {
    echo "{\"status\":\"blocked\",\"error\":\"git_clone_failed: ${CLONE_OUTPUT}\"}"
    exit 0
  }

  # 验证推送权限
  PUSH_OUTPUT=$(cd "$PROJECTS_ROOT" && git push --dry-run 2>&1) || {
    echo "{\"status\":\"blocked\",\"error\":\"git_permission_denied: ${PUSH_OUTPUT}\"}"
    exit 0
  }

  echo '{"status":"ready","error":""}'

# ---- commit_and_push ----
elif [[ "$ACTION" == "commit_and_push" ]]; then
  if [[ -z "$PROJECTS_ROOT" ]]; then
    echo '{"error":"缺少必填参数: --projects_root"}' >&2
    exit 1
  fi
  if [[ ! -d "$PROJECTS_ROOT" ]]; then
    echo "{\"committed\":false,\"commit_sha\":\"\",\"packages\":[]}"
    exit 0
  fi

  cd "$PROJECTS_ROOT"

  # 清理构建缓存：对每个 CI_ll_* 工程目录调用 clean_project_cache.sh，
  # 确保 linglong/、bins/、reports/、build_cache/、*.layer、*.uab、下载包等不被入库
  echo "== 清理构建缓存 =="
  while IFS= read -r -d '' proj; do
    clean_project_cache "$proj"
  done < <(find "$PROJECTS_ROOT" -maxdepth 1 -type d -name 'CI_ll_*' -print0 2>/dev/null)

  # 暂存变更
  git add . 2>/dev/null || true

  # 提交前守卫：阻止缓存被误提交
  echo "== pre-commit 守卫检查 =="
  if ! pre_commit_guard "$PROJECTS_ROOT"; then
    echo "{\"committed\":false,\"commit_sha\":\"\",\"packages\":[],\"blocked\":\"pre_commit_guard\"}"
    exit 0
  fi

  # 列出暂存文件
  CACHED_FILES=$(git diff --cached --name-only 2>/dev/null || true)

  if [[ -z "$CACHED_FILES" ]]; then
    echo "{\"committed\":false,\"commit_sha\":\"\",\"packages\":[]}"
    exit 0
  fi

  # 提取 CI_ll_ 包名
  PACKAGES=$(echo "$CACHED_FILES" | grep -oP 'CI_ll_\K[^/]+' | sort -u | tr '\n' ',' | sed 's/,$//')

  # 动态生成 commit message
  IFS=',' read -ra PKG_ARRAY <<< "$PACKAGES"
  PKG_COUNT=${#PKG_ARRAY[@]}

  if [[ "$PKG_COUNT" -eq 1 ]]; then
    # 判断是新增还是修改
    if echo "$CACHED_FILES" | grep -q "CI_ll_${PKG_ARRAY[0]}" && ! git log --oneline -1 2>/dev/null | grep -q "CI_ll_${PKG_ARRAY[0]}"; then
      COMMIT_MSG="feat: add debian-rules analysis for ${PKG_ARRAY[0]}"
    else
      COMMIT_MSG="fix: update debian-rules analysis for ${PKG_ARRAY[0]}"
    fi
  elif [[ "$PKG_COUNT" -gt 1 ]]; then
    COMMIT_MSG="feat: add/update multiple packages"
  else
    COMMIT_MSG="chore: update analysis scripts"
  fi

  # commit
  COMMIT_OUTPUT=$(git commit -m "$COMMIT_MSG" 2>&1) || {
    echo "{\"committed\":false,\"commit_sha\":\"\",\"packages\":[]}"
    exit 0
  }

  # 提取 commit SHA
  COMMIT_SHA=$(echo "$COMMIT_OUTPUT" | grep -oP '[0-9a-f]{7,40}' | head -1)

  # push
  PUSH_OUTPUT=$(git push 2>&1) || {
    if [[ -n "$DATA_DIR" ]]; then
      mkdir -p "$(dirname "$DATA_DIR" 2>/dev/null || echo "$DATA_DIR")" 2>/dev/null || true
      echo "git_push_failed, ${PUSH_OUTPUT}" >> "${DATA_DIR}/git.log" 2>/dev/null || true
    fi
    echo "{\"committed\":false,\"commit_sha\":\"${COMMIT_SHA:-}\",\"packages\":[\"${PACKAGES}\"]}"
    exit 0
  }

  # 记录成功结果
  if [[ -n "$DATA_DIR" ]]; then
    mkdir -p "$(dirname "$DATA_DIR" 2>/dev/null || echo "$DATA_DIR")" 2>/dev/null || true
    echo "git_commit_success, ${COMMIT_SHA:-}, $(date +'%Y-%m-%d %H:%M:%S')" >> "${DATA_DIR}/git.log" 2>/dev/null || true
  fi

  # 输出 JSON
  PKG_JSON=$(echo "$PACKAGES" | python3 -c "
import json, sys
p = sys.stdin.read().strip().split(',') if sys.stdin.read().strip() else []
p = [x for x in p if x]
print(json.dumps(p))
" 2>/dev/null || echo "[]")

  echo "{\"committed\":true,\"commit_sha\":\"${COMMIT_SHA:-}\",\"packages\":${PKG_JSON}}"

else
  echo "未知 action: ${ACTION}" >&2
  echo "可用 action: init_repo, commit_and_push" >&2
  exit 1
fi