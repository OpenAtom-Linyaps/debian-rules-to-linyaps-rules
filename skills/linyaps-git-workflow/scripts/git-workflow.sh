#!/usr/bin/env bash
# linyaps-git-workflow: git-workflow.sh
#
# 统一 Git 工作流入口脚本，两种 action：
#   init_repo       — Git 仓库克隆 + 推送权限验证
#   commit_and_push — 清理工程、暂存、动态 commit message、推送
#
# 使用方式：
#   bash git-workflow.sh init_repo --projects_repo=<url> --init_repo_dir=<path>
#   bash git-workflow.sh commit_and_push --init_repo_dir=<path> [--data-dir=<path>]

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
INIT_REPO_DIR=""
DATA_DIR=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	--projects_repo=*) PROJECTS_REPO="${1#*=}" ;;
	--init_repo_dir=*) INIT_REPO_DIR="${1#*=}" ;;
	--data-dir=*) DATA_DIR="${1#*=}" ;;
	*)
		echo "未知参数: $1" >&2
		exit 1
		;;
	esac
	shift
done

# 动态检测远程仓库默认分支（不硬编码）。
# 既有克隆（origin/HEAD 已建立）：git rev-parse --abbrev-ref origin/HEAD → origin/<branch>，去前缀。
# 失败回退：git ls-remote --symref origin HEAD 解析 "ref: refs/heads/<branch>\tHEAD"。
# 两者均失败 → 返回空，调用方据此 blocked。
detect_default_branch() {
	local raw
	raw=$(git rev-parse --abbrev-ref origin/HEAD 2>/dev/null) || raw=""
	raw="${raw#origin/}"
	if [[ -n "$raw" && "$raw" != "HEAD" ]]; then
		echo "$raw"
		return 0
	fi
	raw=$(git ls-remote --symref origin HEAD 2>/dev/null |
		sed -n 's|^ref: refs/heads/\([^ ]*\)	HEAD|\1|p' | head -1)
	if [[ -n "$raw" ]]; then
		echo "$raw"
		return 0
	fi
	return 1
}

sync_upstream() {
	# 提交推送前与上游同步：fetch → 落后则 stash -u + rebase + stash pop
	# 返回 0 表示已同步/无需同步；返回非 0 表示冲突中断（已输出 blocked JSON）
	echo "== 与上游同步（stash -u + rebase）=="
	if ! git fetch origin 2>&1; then
		echo "[WARN] git fetch 失败，跳过同步" >&2
		return 0
	fi
	local target_branch remote behind
	target_branch=$(detect_default_branch) || {
		echo "[ERROR] 无法检测远程默认分支" >&2
		return 1
	}
	remote="origin/$target_branch"
	git rev-parse --verify "$remote" >/dev/null 2>&1 || {
		echo "[WARN] 无远程分支 $remote，跳过同步" >&2
		return 0
	}
	behind=$(git rev-list --count "HEAD..$remote" 2>/dev/null || echo 0)
	if [[ "$behind" == "0" ]]; then
		return 0
	fi
	echo "本地落后上游 $behind 个提交，开始安全同步"

	# 仅在有本地改动（含未跟踪）时才 stash，避免空 stash 造成的误报
	local stashed=0
	if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
		if ! git stash push -u -m "linyaps-prepull" 2>&1; then
			echo '{"committed":false,"commit_sha":"","packages":[],"blocked":"stash_failed"}' >&2
			return 1
		fi
		stashed=1
	fi

	# 手动 stash 后工作区已干净，故不用 --autostash：其内部 stash/pop 会与手动 stash 冲突
	if ! git rebase "$remote" 2>&1; then
		git rebase --abort 2>/dev/null || true
		echo '{"committed":false,"commit_sha":"","packages":[],"blocked":"rebase_conflict"}' >&2
		return 1
	fi

	# 仅当确已 stash 且 stash 仍存在时才恢复，避免"空 stash pop"误报
	if [[ "$stashed" == "1" ]] && git rev-parse --verify refs/stash >/dev/null 2>&1; then
		if ! git stash pop 2>&1; then
			echo "[WARN] stash 恢复冲突，已保留改动，请人工处理，阻断本次提交" >&2
			echo '{"committed":false,"commit_sha":"","packages":[],"blocked":"stash_conflict"}' >&2
			return 1
		fi
	fi
	return 0
}

output_json() {
	echo "$1"
}

# ---- init_repo ----
if [[ "$ACTION" == "init_repo" ]]; then
	if [[ -z "$PROJECTS_REPO" ]]; then
		echo '{"status":"blocked","error":"git_repo_not_configured"}'
		exit 0
	fi
	if [[ -z "$INIT_REPO_DIR" ]]; then
		INIT_REPO_DIR="./projects/init"
	fi

	# git clone；若已存在且为 git 仓库，则改为同步而非重建
	if [[ -d "$INIT_REPO_DIR/.git" ]]; then
		CLONE_OUTPUT=$(cd "$INIT_REPO_DIR" && sync_upstream 2>&1) || {
			echo "{\"status\":\"blocked\",\"error\":\"git_sync_failed: ${CLONE_OUTPUT}\"}"
			exit 0
		}
	else
		CLONE_OUTPUT=$(git clone "$PROJECTS_REPO" "$INIT_REPO_DIR" 2>&1) || {
			echo "{\"status\":\"blocked\",\"error\":\"git_clone_failed: ${CLONE_OUTPUT}\"}"
			exit 0
		}
	fi

	# 显式切到远程默认分支并对齐，确保后续 push 目标为默认分支（不受克隆残留分支影响）
	cd "$INIT_REPO_DIR"
	DEFAULT_BRANCH=$(detect_default_branch) || {
		echo "{\"status\":\"blocked\",\"error\":\"git_detect_default_branch_failed\"}"
		exit 0
	}
	git checkout "$DEFAULT_BRANCH" 2>&1 || {
		echo "{\"status\":\"blocked\",\"error\":\"git_checkout_default_failed\"}"
		exit 0
	}
	# 对齐到 origin/<默认分支>（快进，不产生分叉）
	git merge --ff-only "origin/$DEFAULT_BRANCH" 2>&1 || true

	# 验证推送权限
	PUSH_OUTPUT=$(cd "$INIT_REPO_DIR" && git push --dry-run origin "$DEFAULT_BRANCH" 2>&1) || {
		echo "{\"status\":\"blocked\",\"error\":\"git_permission_denied: ${PUSH_OUTPUT}\"}"
		exit 0
	}

	echo '{"status":"ready","error":""}'

# ---- commit_and_push ----
elif [[ "$ACTION" == "commit_and_push" ]]; then
	if [[ -z "$INIT_REPO_DIR" ]]; then
		echo '{"error":"缺少必填参数: --init_repo_dir"}' >&2
		exit 1
	fi
	if [[ ! -d "$INIT_REPO_DIR" ]]; then
		echo "{\"committed\":false,\"commit_sha\":\"\",\"packages\":[]}"
		exit 0
	fi

	cd "$INIT_REPO_DIR"

	# 显式切到远程默认分支，确保提交与推送目标为默认分支（不受克隆残留分支影响）
	DEFAULT_BRANCH=$(detect_default_branch) || {
		echo "{\"committed\":false,\"commit_sha\":\"\",\"packages\":[],\"blocked\":\"detect_default_branch_failed\"}"
		exit 0
	}
	git checkout "$DEFAULT_BRANCH" 2>&1 || {
		echo "{\"committed\":false,\"commit_sha\":\"\",\"packages\":[],\"blocked\":\"checkout_default_failed\"}"
		exit 0
	}

	# 清理构建缓存：对每个 CI_ll_* 工程目录调用 clean_project_cache.sh，
	# 确保 linglong/、bins/、reports/、build_cache/、*.layer、*.uab、下载包等不被入库
	echo "== 清理构建缓存 =="
	while IFS= read -r -d '' proj; do
		clean_project_cache "$proj"
	done < <(find "$INIT_REPO_DIR" -maxdepth 1 -type d -name 'CI_ll_*' -print0 2>/dev/null)

	# 推送前先与上游同步（stash -u + rebase），避免本地落后导致 push 被拒
	if ! sync_upstream; then
		exit 0
	fi

	# 暂存变更
	git add . 2>/dev/null || true

	# 提交前守卫：阻止缓存被误提交
	echo "== pre-commit 守卫检查 =="
	if ! pre_commit_guard "$INIT_REPO_DIR"; then
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
	IFS=',' read -ra PKG_ARRAY <<<"$PACKAGES"
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
	PUSH_OUTPUT=$(git push origin "$DEFAULT_BRANCH" 2>&1) || {
		if [[ -n "$DATA_DIR" ]]; then
			mkdir -p "$(dirname "$DATA_DIR" 2>/dev/null || echo "$DATA_DIR")" 2>/dev/null || true
			echo "git_push_failed, ${PUSH_OUTPUT}" >>"${DATA_DIR}/git.log" 2>/dev/null || true
		fi
		echo "{\"committed\":false,\"commit_sha\":\"${COMMIT_SHA:-}\",\"packages\":[\"${PACKAGES}\"]}"
		exit 0
	}

	# 记录成功结果
	if [[ -n "$DATA_DIR" ]]; then
		mkdir -p "$(dirname "$DATA_DIR" 2>/dev/null || echo "$DATA_DIR")" 2>/dev/null || true
		echo "git_commit_success, ${COMMIT_SHA:-}, $(date +'%Y-%m-%d %H:%M:%S')" >>"${DATA_DIR}/git.log" 2>/dev/null || true
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
