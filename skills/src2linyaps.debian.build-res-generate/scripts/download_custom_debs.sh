#!/bin/bash
# src2linyaps.debian.build-res-generate
# 静态下载解压脚本，由 build: 段在 ll-builder 容器内调用
# 解析脚本同级目录下的 custom_debs_urls.conf，下载并解压 deb 到 ${PREFIX}
# 不依赖外部 fetch 脚本，支持用户手动创建 conf
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/custom_debs_urls.conf"
# 解压目标：第一个参数（build: 段传入 ${PREFIX}），回退 ${PREFIX} 环境变量
TARGET_DIR="${1:-${PREFIX:-/opt/apps/unknown}}"

if [ ! -f "$CONF_FILE" ]; then
	echo "INFO: 未找到 custom_debs_urls.conf，无需下载" >&2
	exit 0
fi

# source 前临时关闭 set -u
set +u
source "$CONF_FILE"
set -u

if [ ${#CUSTOM_DEB_URLS[@]} -eq 0 ]; then
	echo "INFO: custom_debs_urls.conf 中无 URL，无需下载" >&2
	exit 0
fi

url_decode() {
	python3 -c 'import urllib.parse,sys;print(urllib.parse.unquote(sys.argv[1]))' "$1"
}

DEB_CACHE="/tmp/lingyaps-custom-debs"
IMPORTANT_DIRS=(usr bin sbin lib lib32 lib64 libexec include share local)

mkdir -p "$TARGET_DIR" "$DEB_CACHE"

FAIL_COUNT=0
for url in "${CUSTOM_DEB_URLS[@]}"; do
	deb_file="$DEB_CACHE/$(url_decode "$(basename "$url")")"
	echo "下载: $url"
	if ! wget -q --tries=3 "$url" -O "$deb_file"; then
		echo "WARN: 下载失败: $url" >&2
		FAIL_COUNT=$((FAIL_COUNT + 1))
		continue
	fi
	if ! dpkg-deb -I "$deb_file" >/dev/null 2>&1; then
		echo "WARN: 下载内容非有效 deb（可能为错误页）: $url" >&2
		FAIL_COUNT=$((FAIL_COUNT + 1))
		rm -f "$deb_file"
		continue
	fi
	echo "解压: $deb_file"
	EXTRACT_DIR=$(mktemp -d)
	if command -v dpkg >/dev/null 2>&1; then
		dpkg -x "$deb_file" "$EXTRACT_DIR"
	else
		dpkg-deb -x "$deb_file" "$EXTRACT_DIR"
	fi
	if [ $? -ne 0 ]; then
		echo "WARN: 解压失败: $deb_file" >&2
		FAIL_COUNT=$((FAIL_COUNT + 1))
		rm -f "$deb_file"
		rm -rf "$EXTRACT_DIR"
		continue
	fi
	for entry in "$EXTRACT_DIR"/*; do
		[ -e "$entry" ] || continue
		name="$(basename "$entry")"
		important=0
		for d in "${IMPORTANT_DIRS[@]}"; do
			if [ "$d" = "$name" ]; then
				important=1
				break
			fi
		done
		[ "$important" -eq 1 ] || continue
		if [ "$name" = "usr" ] && [ -d "$entry" ]; then
			for sub in "$entry"/*; do
				[ -e "$sub" ] || continue
				if ! cp -rf "$sub" "$TARGET_DIR/"; then
					echo "WARN: 复制失败: $sub -> $TARGET_DIR/" >&2
					FAIL_COUNT=$((FAIL_COUNT + 1))
				fi
			done
		else
			if ! cp -rf "$entry" "$TARGET_DIR/"; then
				echo "WARN: 复制失败: $entry -> $TARGET_DIR/" >&2
				FAIL_COUNT=$((FAIL_COUNT + 1))
			fi
		fi
	done
	rm -rf "$EXTRACT_DIR"
	rm -f "$deb_file"
done

TOTAL=${#CUSTOM_DEB_URLS[@]}
SUCCESS=$((TOTAL - FAIL_COUNT))
echo "完成: 成功 $SUCCESS/$TOTAL 个自定义 deb 已解压到 $TARGET_DIR"
[ "$FAIL_COUNT" -eq 0 ] || echo "WARN: $FAIL_COUNT 个包处理失败" >&2
