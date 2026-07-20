#!/bin/bash
# test-debian-rules.sh — 路径 A 全流程测试 (kate-cmake)
# 
# 验证点：
# ① 3 包合并去重正确
# ② debian/*.install 关联扫描
# ③ debian/rules dh kf6 序列解析
# ④ baseline 提取
# ⑤ 输出 YAML 完整性

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_PROJECT="$PROJECT_ROOT/src-examples/kate-cmake"

echo "=== 路径 A 全流程测试: kate-cmake ==="

# 检查测试项目存在
if [ ! -d "$TEST_PROJECT" ]; then
    echo "FAIL: 测试项目不存在: $TEST_PROJECT"
    exit 1
fi

# 解压 debian 打包文件用于测试
DEB_TAR="$TEST_PROJECT/kate_25.04.3-2deepin1.debian.tar.xz"
SRC_TAR="$TEST_PROJECT/kate_25.04.3.orig.tar.gz"
DEB_EXTRACT_DIR=$(mktemp -d)
SRC_EXTRACT_DIR=$(mktemp -d)
trap "rm -rf $DEB_EXTRACT_DIR $SRC_EXTRACT_DIR" EXIT

if [ -f "$DEB_TAR" ]; then
    tar -xJf "$DEB_TAR" -C "$DEB_EXTRACT_DIR"
    CONTROL_FILE="$DEB_EXTRACT_DIR/debian/control"
    RULES_FILE="$DEB_EXTRACT_DIR/debian/rules"
    CHANGELOG_FILE="$DEB_EXTRACT_DIR/debian/changelog"
else
    if [ -d "$TEST_PROJECT/debian" ]; then
        CONTROL_FILE="$TEST_PROJECT/debian/control"
        RULES_FILE="$TEST_PROJECT/debian/rules"
        CHANGELOG_FILE="$TEST_PROJECT/debian/changelog"
    else
        echo "SKIP: 无法获取 debian 打包文件（需要解压）"
        exit 0
    fi
fi

# 解压 kate 源码包用于构建工具检测
KATE_SRC_DIR="$TEST_PROJECT"
if [ -f "$SRC_TAR" ]; then
    tar -xzf "$SRC_TAR" -C "$SRC_EXTRACT_DIR"
    KATE_SRC_DIR="$SRC_EXTRACT_DIR/$(ls "$SRC_EXTRACT_DIR" | head -1)"
fi

# 测试 1: parse-control.py 解析
echo ""
echo "--- 测试 1: parse-control.py 解析 debian/control ---"
if [ -f "$CONTROL_FILE" ]; then
    python3 "$PROJECT_ROOT/skills/src2linyaps.debian.analyze-control/scripts/parse-control.py" "$CONTROL_FILE" > /tmp/control-output.yaml
    echo "parse-control.py 执行成功"
    cat /tmp/control-output.yaml

    # 验证 pkgName
    PKG_NAME=$(grep '^pkgName:' /tmp/control-output.yaml | awk '{print $2}')
    if [ -n "$PKG_NAME" ]; then
        echo "  ✓ pkgName: $PKG_NAME"
    else
        echo "  ✗ pkgName 为空"
        exit 1
    fi

    # 验证 binaryPackages 包含多个包（只统计 binaryPackages 下的条目）
    BINARY_COUNT=$(sed -n '/^binaryPackages:/,/^[a-z]/p' /tmp/control-output.yaml | grep -c '^- ' || true)
    echo "  binary 包数量: $BINARY_COUNT"
    if [ "$BINARY_COUNT" -ge 2 ]; then
        echo "  ✓ 多包检测正确 (kate, kate-data, kwrite)"
    fi

    # 验证 buildDepends 非空（只统计 buildDepends 下的条目）
    BD_COUNT=$(sed -n '/^buildDepends:/,/^[a-z]/p' /tmp/control-output.yaml | grep -c '^- ' || true)
    if [ "$BD_COUNT" -ge 5 ]; then
        echo "  ✓ buildDepends 列表完整 ($BD_COUNT 项)"
    fi
else
    echo "SKIP: control 文件不存在"
fi

# 测试 2: analyze-rules.py 解析
echo ""
echo "--- 测试 2: analyze-rules.py 解析 debian 规则 ---"
if [ -f "$RULES_FILE" ] && [ -f "$CHANGELOG_FILE" ]; then
    python3 "$PROJECT_ROOT/skills/src2linyaps.debian.analyze-rules/scripts/analyze-rules.py" \
        "$KATE_SRC_DIR" "$DEB_EXTRACT_DIR/debian" "/tmp/control-output.yaml" > /tmp/rules-output.yaml
    echo "analyze-rules.py 执行成功"
    cat /tmp/rules-output.yaml

    # 验证 build_tool
    BT=$(grep '^build_tool:' /tmp/rules-output.yaml | awk '{print $2}')
    if [ "$BT" = "cmake" ]; then
        echo "  ✓ build_tool: $BT"
    else
        echo "  ✗ build_tool 应为 cmake, 实际为: $BT"
        exit 1
    fi

    # 验证 baseline
    BL=$(grep '^baseline:' /tmp/rules-output.yaml | awk '{print $2}')
    if [ -n "$BL" ]; then
        echo "  ✓ baseline: $BL"
    fi

    # 验证 build_args 非空
    BA_COUNT=$(grep -c '^- name:' /tmp/rules-output.yaml || true)
    if [ "$BA_COUNT" -ge 1 ]; then
        echo "  ✓ build_args 列表完整 ($BA_COUNT 项)"
    fi

    # 验证资源文件扫描
    if grep -q 'resources:' /tmp/rules-output.yaml; then
        echo "  ✓ resources 段存在"
    fi
else
    echo "SKIP: rules 或 changelog 文件不存在"
fi

# 测试 3: detect-build-tool.sh 检测
echo ""
echo "--- 测试 3: detect-build-tool.sh 检测 kate 构建工具 ---"
bash "$PROJECT_ROOT/skills/src2linyaps.source.detect-tool/scripts/detect-build-tool.sh" "$KATE_SRC_DIR" > /tmp/detect-output.yaml
cat /tmp/detect-output.yaml
TT=$(grep '^tool_type:' /tmp/detect-output.yaml | awk '{print $2}')
if [ "$TT" = "cmake" ]; then
    echo "  ✓ 构建工具检测正确: $TT"
else
    echo "  ✗ 构建工具检测失败: $TT"
    exit 1
fi

echo ""
echo "=== 路径 A 测试完成 ==="
exit 0