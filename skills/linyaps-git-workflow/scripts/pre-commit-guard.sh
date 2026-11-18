#!/usr/bin/env bash
# linyaps-git-workflow: pre-commit-guard.sh
#
# 提交前守卫：在 git add . 之后检查指定工程目录的暂存变更，
# 命中缓存模式（*.layer、*.uab、linglong/、bins/、reports/、
# build_cache/、.linyaps-locks/ 等）即退出码 1，阻断提交。
#
# 用法:
#   pre-commit-guard.sh <project_dir> [--ignore-patterns=<regex>]
#
# 退出码:
#   0  通过（无缓存命中）
#   1  命中缓存模式，阻断提交
#   2  参数/环境错误

set -euo pipefail

PROJECT_DIR=""
IGNORE_PATTERNS=""

for arg in "$@"; do
  case "$arg" in
    --ignore-patterns=*) IGNORE_PATTERNS="${arg#*=}" ;;
    -*) echo "未知选项: $arg" >&2; exit 2 ;;
    *)
      if [[ -z "$PROJECT_DIR" ]]; then
        PROJECT_DIR="$arg"
      else
        echo "错误: 过多位置参数: $arg" >&2; exit 2
      fi
      ;;
  esac
done

if [[ -z "$PROJECT_DIR" ]]; then
  echo "错误: 缺少必填参数 <project_dir>" >&2
  echo "用法: pre-commit-guard.sh <project_dir> [--ignore-patterns=<regex>]" >&2
  exit 2
fi

if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "错误: 目录不存在: $PROJECT_DIR" >&2
  exit 2
fi

# 默认阻断模式（正则，匹配暂存文件路径）
DEFAULT_PATTERN='(\.layer$|\.uab$|(^|/)linglong/|(^|/)bins/|(^|/)reports/|(^|/)build_cache/|(^|/)\.linyaps-locks/)'
PATTERN="${IGNORE_PATTERNS:-$DEFAULT_PATTERN}"

cd "$PROJECT_DIR"

# 若目录本身不是 git 仓库，向父目录查找。工程通常位于 projects_root 仓库内。
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "错误: $PROJECT_DIR 不在任何 git 仓库内" >&2
  exit 2
fi

# 只检查本工程目录内的暂存文件（--relative 使路径相对当前目录）
CACHED_FILES=$(git diff --cached --name-only --diff-filter=d --relative 2>/dev/null || true)

if [[ -z "$CACHED_FILES" ]]; then
  echo "[守卫] 通过：该工程目录无暂存变更"
  exit 0
fi

# 检查命中
HITS=$(echo "$CACHED_FILES" | grep -E "$PATTERN" || true)

if [[ -n "$HITS" ]]; then
  echo "[守卫] 阻断：检测到缓存文件被暂存，禁止提交：" >&2
  echo "$HITS" | sed 's/^/    /' >&2
  echo "请先运行 clean_project_cache.sh <project_dir> 清理缓存后重试。" >&2
  exit 1
fi

echo "[守卫] 通过：暂存变更不含缓存文件"
exit 0
