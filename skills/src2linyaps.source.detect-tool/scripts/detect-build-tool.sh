#!/bin/bash
# detect-build-tool.sh — 扫描项目根目录，识别构建工具类型
#
# 用法:
#   bash detect-build-tool.sh <project_path>
#
# 输出 (stdout, YAML):
#   tool_type: cmake|meson|make|autotools|unknown
#   confidence: high|medium|low

set -euo pipefail

PROJECT_PATH="${1:-}"
if [ -z "$PROJECT_PATH" ]; then
    echo "tool_type: unknown"
    echo "confidence: low"
    exit 1
fi

if [ ! -d "$PROJECT_PATH" ]; then
    echo "tool_type: unknown"
    echo "confidence: low"
    exit 1
fi

# Priority order: cmake -> meson -> make -> autotools
if [ -f "$PROJECT_PATH/CMakeLists.txt" ]; then
    echo "tool_type: cmake"
    echo "confidence: high"
    exit 0
fi

if [ -f "$PROJECT_PATH/meson.build" ]; then
    echo "tool_type: meson"
    echo "confidence: high"
    exit 0
fi

if [ -f "$PROJECT_PATH/Makefile" ] || [ -f "$PROJECT_PATH/GNUmakefile" ] || [ -f "$PROJECT_PATH/makefile" ]; then
    echo "tool_type: make"
    echo "confidence: high"
    exit 0
fi

if [ -f "$PROJECT_PATH/configure" ] || [ -f "$PROJECT_PATH/configure.ac" ]; then
    echo "tool_type: autotools"
    echo "confidence: high"
    exit 0
fi

# No match found
echo "tool_type: unknown"
echo "confidence: low"
exit 0