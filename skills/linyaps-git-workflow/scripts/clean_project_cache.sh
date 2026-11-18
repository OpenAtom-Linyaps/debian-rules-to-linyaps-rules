#!/usr/bin/env bash
# linyaps-git-workflow: clean_project_cache.sh
#
# 提交 git 前清理 CI_ll_* 工程目录内的构建缓存与下载产物。
# 仅接受具体目录路径，不支持 --all / 项目名扫描。
#
# 用法:
#   clean_project_cache.sh <project_dir> [--dry-run]

set -euo pipefail

# ============================================================
# 参数解析
# ============================================================
PROJECT_DIR=""
DRY_RUN=false

for arg in "$@"; do
	case "$arg" in
	--dry-run) DRY_RUN=true ;;
	-*)
		echo "未知选项: $arg" >&2
		exit 1
		;;
	*)
		if [[ -z "$PROJECT_DIR" ]]; then
			PROJECT_DIR="$arg"
		else
			echo "错误: 过多位置参数: $arg" >&2
			exit 1
		fi
		;;
	esac
done

if [[ -z "$PROJECT_DIR" ]]; then
	echo "错误: 缺少必填参数 <project_dir>" >&2
	echo "用法: clean_project_cache.sh <project_dir> [--dry-run]" >&2
	exit 1
fi

# 拒绝 --all 等整库清理模式（本脚本只允许具体目录）
if [[ "$PROJECT_DIR" == "--all" || "$PROJECT_DIR" == "." || "$PROJECT_DIR" == "/" ]]; then
	echo "错误: 仅允许指定具体工程目录，禁止整库/根目录清理" >&2
	exit 1
fi

# 解析为绝对路径并校验存在
PROJECT_DIR="$(readlink -f "$PROJECT_DIR" 2>/dev/null || echo "$PROJECT_DIR")"
if [[ ! -d "$PROJECT_DIR" ]]; then
	echo "错误: 目录不存在: $PROJECT_DIR" >&2
	exit 1
fi

# 校验为 CI_ll_* 工程目录
BASENAME="$(basename "$PROJECT_DIR")"
if [[ "$BASENAME" != CI_ll_* ]]; then
	echo "警告: '$BASENAME' 不是 CI_ll_* 工程目录，继续尝试清理（仅删除已知缓存模式）" >&2
fi

# ============================================================
# 工具函数
# ============================================================
removed_count=0

remove_path() {
	# $1: 绝对路径
	local p="$1"
	if [[ -e "$p" || -L "$p" ]]; then
		removed_count=$((removed_count + 1))
		if [[ "$DRY_RUN" == "true" ]]; then
			echo "[dry-run] 将删除: $p"
		else
			rm -rf "$p"
			echo "[清理] 已删除: $p"
		fi
	fi
}

remove_glob() {
	# $1: 文件名模式（相对 project dir，匹配普通文件）
	local pattern="$1"
	local f
	while IFS= read -r f; do
		[[ -z "$f" ]] && continue
		removed_count=$((removed_count + 1))
		if [[ "$DRY_RUN" == "true" ]]; then
			echo "[dry-run] 将删除: $f"
		else
			rm -f "$f"
			echo "[清理] 已删除: $f"
		fi
	done < <(find "$PROJECT_DIR" -maxdepth 3 -type f -name "$pattern" 2>/dev/null)
}

# ============================================================
# 核心构建缓存
# ============================================================
for sub in linglong bins reports build_cache file_res; do
	remove_path "${PROJECT_DIR}/${sub}"
done

# 构建产物 layer / uab（工程根目录及 bins 下）
remove_glob "*.layer"
remove_glob "*.uab"

# ============================================================
# 下载产物（归档包）
# ============================================================
for pat in '*.deb' '*.tar.gz' '*.tar.bz2' '*.tar.xz' '*.tar.zst' '*.tgz' '*.zip'; do
	remove_glob "$pat"
done

# ============================================================
# src/ 与 source/ —— 仅在确认为下载/解压缓存时删除。
# 判断依据：若该目录包含已被 git 跟踪的文件，则为真实源码工程，
# 必须保留；只有完全未被跟踪（纯下载/解压缓存）时才删除。
# ============================================================
for sub in src source; do
	dir="${PROJECT_DIR}/${sub}"
	if [[ -d "$dir" ]]; then
		if git -C "$PROJECT_DIR" ls-files --error-unmatch -- "$sub" >/dev/null 2>&1; then
			echo "[保留] $sub 为已跟踪的工程源/源文件，不删除"
		else
			remove_path "$dir"
		fi
	fi
done

# ============================================================
# 汇总
# ============================================================
echo ""
if [[ "$DRY_RUN" == "true" ]]; then
	echo "== dry-run 完成：将删除 $removed_count 项缓存 =="
else
	echo "== 清理完成：共删除 $removed_count 项缓存 =="
fi

if [[ -d "$PROJECT_DIR" ]]; then
	echo "工程目录体积: $(du -sh "$PROJECT_DIR" 2>/dev/null | awk '{print $1}')"
fi

exit 0
