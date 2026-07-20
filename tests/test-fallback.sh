#!/bin/bash
# test-fallback.sh — 路径 B 全流程测试 (mame-makefile + scrcpy-meson-build)
#
# 验证点：
# ① 自动检测 Makefile 构建工具
# ② 自动检测 Meson 构建工具
# ③ 对应构建参数提取正确性

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MAME_PROJECT="$PROJECT_ROOT/src-examples/mame-makefile"
SCRCPY_PROJECT="$PROJECT_ROOT/src-examples/scrcpy-meson-build"

echo "=== 路径 B 全流程测试: fallback 检测 ==="

# 测试 1: mame-makefile — 检测 Makefile 构建工具
echo ""
echo "--- 测试 1: mame-makefile — detect-build-tool.sh ---"
if [ ! -d "$MAME_PROJECT" ]; then
    echo "SKIP: mame-makefile 项目不存在"
    exit 0
fi

# 解压 mame 源码用于测试
MAME_TAR="$MAME_PROJECT/mame-mame0288.tar.gz"
MAME_EXTRACT_DIR=$(mktemp -d)
trap "rm -rf $MAME_EXTRACT_DIR" EXIT

if [ -f "$MAME_TAR" ]; then
    tar -xzf "$MAME_TAR" -C "$MAME_EXTRACT_DIR"
    MAME_SRC="$MAME_EXTRACT_DIR/$(ls "$MAME_EXTRACT_DIR" | head -1)"
else
    MAME_SRC="$MAME_PROJECT"
fi

bash "$PROJECT_ROOT/skills/src2linyaps.source.detect-tool/scripts/detect-build-tool.sh" "$MAME_SRC" > /tmp/detect-mame.yaml
cat /tmp/detect-mame.yaml
TT=$(grep '^tool_type:' /tmp/detect-mame.yaml | awk '{print $2}')
if [ "$TT" = "make" ]; then
    echo "  ✓ MAME 构建工具检测正确: $TT"
else
    echo "  ✗ MAME 构建工具检测失败: $TT"
    exit 1
fi

# 测试 2: mame-makefile — extract-build-args.py
echo ""
echo "--- 测试 2: mame-makefile — extract-build-args.py ---"
python3 "$PROJECT_ROOT/skills/src2linyaps.source.analyze-args/scripts/extract-build-args.py" \
    "$MAME_SRC" "make" > /tmp/args-mame.yaml
cat /tmp/args-mame.yaml

BA_COUNT=$(grep -c '^- name:' /tmp/args-mame.yaml || true)
if [ "$BA_COUNT" -ge 1 ]; then
    echo "  ✓ MAME build_args 提取成功 ($BA_COUNT 项)"
else
    echo "  ✗ MAME build_args 提取失败"
    exit 1
fi

# 测试 3: scrcpy-meson-build — 检测 Meson 构建工具
echo ""
echo "--- 测试 3: scrcpy-meson-build — detect-build-tool.sh ---"
if [ ! -d "$SCRCPY_PROJECT" ]; then
    echo "SKIP: scrcpy-meson-build 项目不存在"
    exit 0
fi

SCRCPY_TAR="$SCRCPY_PROJECT/scrcpy-v2.3.1.tar.bz2"
SCRCPY_EXTRACT_DIR=$(mktemp -d)
trap "rm -rf $SCRCPY_EXTRACT_DIR $MAME_EXTRACT_DIR" EXIT

if [ -f "$SCRCPY_TAR" ]; then
    tar -xjf "$SCRCPY_TAR" -C "$SCRCPY_EXTRACT_DIR"
    SCRCPY_SRC="$SCRCPY_EXTRACT_DIR/$(ls "$SCRCPY_EXTRACT_DIR" | head -1)"
else
    SCRCPY_SRC="$SCRCPY_PROJECT"
fi

bash "$PROJECT_ROOT/skills/src2linyaps.source.detect-tool/scripts/detect-build-tool.sh" "$SCRCPY_SRC" > /tmp/detect-scrcpy.yaml
cat /tmp/detect-scrcpy.yaml
TT=$(grep '^tool_type:' /tmp/detect-scrcpy.yaml | awk '{print $2}')
if [ "$TT" = "meson" ]; then
    echo "  ✓ scrcpy 构建工具检测正确: $TT"
else
    echo "  ✗ scrcpy 构建工具检测失败: $TT"
    exit 1
fi

# 测试 4: scrcpy-meson-build — extract-build-args.py
echo ""
echo "--- 测试 4: scrcpy-meson-build — extract-build-args.py ---"
python3 "$PROJECT_ROOT/skills/src2linyaps.source.analyze-args/scripts/extract-build-args.py" \
    "$SCRCPY_SRC" "meson" > /tmp/args-scrcpy.yaml
cat /tmp/args-scrcpy.yaml

BA_COUNT=$(grep -c '^- name:' /tmp/args-scrcpy.yaml || true)
if [ "$BA_COUNT" -ge 1 ]; then
    echo "  ✓ scrcpy build_args 提取成功 ($BA_COUNT 项)"
else
    echo "  ✗ scrcpy build_args 提取失败"
    exit 1
fi

echo ""
echo "=== 路径 B 测试完成 ==="
exit 0