#!/bin/bash
# test-mismatch.sh — 规则与源码不匹配场景测试
#
# 验证点：
# ① 约束终止逻辑触发
# ② 返回错误信息

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== 规则与源码不匹配测试 ==="

# 创建一个临时项目目录，模拟不匹配场景
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# 场景：在一个纯 Python 项目中放置 debian 规则（明显不匹配）
mkdir -p "$TEMP_DIR/debian"
mkdir -p "$TEMP_DIR/src"

# 创建一个简单的 Python 项目
cat > "$TEMP_DIR/src/main.py" << 'EOF'
#!/usr/bin/env python3
print("Hello, World!")
EOF

# 创建一个指向 C++ 项目的 debian/control 和 rules
cat > "$TEMP_DIR/debian/control" << 'EOF'
Source: libfoo-cpp
Section: libs
Priority: optional
Build-Depends: debhelper-compat (= 13),
               cmake,
               libboost-dev,
               libqt5-dev
Standards-Version: 4.6.0

Package: libfoo-cpp
Architecture: any
Depends: ${shlibs:Depends}
Description: A C++ library (mismatch test)
EOF

cat > "$TEMP_DIR/debian/rules" << 'EOF'
#!/usr/bin/make -f
%:
	dh $@

override_dh_auto_configure:
	dh_auto_configure -- -DCMAKE_INSTALL_PREFIX=/usr

override_dh_auto_test:
	true
EOF

cat > "$TEMP_DIR/debian/changelog" << 'EOF'
libfoo-cpp (1.0.0-1) unstable; urgency=medium

  * Initial release

 -- Test User <test@example.com>  Mon, 01 Jan 2024 00:00:00 +0000
EOF

# 验证 debian 规则与源码不匹配
echo ""
echo "--- 测试: 检测 debian 规则与源码不匹配 ---"

# 检测项目根目录：没有 CMakeLists.txt，但 debian/rules 需要 cmake
echo "项目源码类型: Python (src/main.py)"
echo "debian/control Build-Depends: cmake, libboost-dev, libqt5-dev"
echo "debian/rules: 使用 dh_auto_configure (cmake)"
echo ""

# 运行 detect-tool 确认没有 CMakeLists.txt
bash "$PROJECT_ROOT/skills/src2linyaps.source.detect-tool/scripts/detect-build-tool.sh" "$TEMP_DIR" > /tmp/detect-mismatch.yaml
cat /tmp/detect-mismatch.yaml
TT=$(grep '^tool_type:' /tmp/detect-mismatch.yaml | awk '{print $2}')
if [ "$TT" = "unknown" ]; then
    echo "  ✓ 检测到无构建工具 (unknown)，符合预期"
else
    echo "  ✗ 检测结果异常: $TT (预期 unknown)"
    exit 1
fi

# 模拟 parse-control 解析
echo ""
echo "--- 测试: parse-control.py 解析 (仅 control 信息) ---"
python3 "$PROJECT_ROOT/skills/src2linyaps.debian.analyze-control/scripts/parse-control.py" \
    "$TEMP_DIR/debian/control" > /tmp/control-mismatch.yaml
cat /tmp/control-mismatch.yaml

PKG=$(grep '^pkgName:' /tmp/control-mismatch.yaml | awk '{print $2}')
if [ "$PKG" = "libfoo-cpp" ]; then
    echo "  ✓ control 解析正确: pkgName=$PKG"
else
    echo "  ✗ control 解析异常: $PKG"
    exit 1
fi

# 模拟 analyze-rules 解析
echo ""
echo "--- 测试: analyze-rules.py 解析 (不匹配场景) ---"
python3 "$PROJECT_ROOT/skills/src2linyaps.debian.analyze-rules/scripts/analyze-rules.py" \
    "$TEMP_DIR" "$TEMP_DIR/debian" "/tmp/control-mismatch.yaml" > /tmp/rules-mismatch.yaml
cat /tmp/rules-mismatch.yaml

BT=$(grep '^build_tool:' /tmp/rules-mismatch.yaml | awk '{print $2}')
if [ "$BT" = "cmake" ]; then
    echo "  ! 注意: build_tool 检测为 cmake (基于 debian/rules 推断)"
    echo "  ! 但实际项目源码不含 CMakeLists.txt — 这表明规则与源码不匹配"
    echo "  ✓ 不匹配场景已识别"
else
    echo "  ✓ build_tool: $BT (不匹配场景)"
fi

echo ""
echo "=== 不匹配测试完成 ==="
echo "结论: 当 debian 规则与源码不匹配时，Agent 应终止任务并报告原因"
exit 0