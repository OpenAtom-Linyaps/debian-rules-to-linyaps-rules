#!/usr/bin/env python3
"""
extract-build-args.py — 根据构建工具类型提取可修改编译参数及默认值。

用法:
    python3 extract-build-args.py <project_path> <tool_type>

tool_type: cmake | meson | make | autotools

输出 (stdout, YAML格式):
    build_tool, build_tool_type, build_args[]
"""

import sys
import os
import re
import yaml


def extract_cmake_args(project_path: str) -> list:
    """Extract build args from CMakeLists.txt."""
    args = [
        {'name': 'CMAKE_INSTALL_PREFIX', 'default': '/usr/local'},
        {'name': 'CMAKE_BUILD_TYPE', 'default': 'Release'},
    ]
    cmake_file = os.path.join(project_path, 'CMakeLists.txt')
    if os.path.exists(cmake_file):
        with open(cmake_file, 'r', encoding='utf-8') as f:
            content = f.read()
        # Look for set(CMAKE_INSTALL_PREFIX ...) patterns
        for arg in args:
            m = re.search(
                r'set\s*\(\s*' + re.escape(arg['name']) + r'\s+(\S+)',
                content, re.IGNORECASE
            )
            if m:
                arg['default'] = m.group(1).strip().rstrip(')')
    return args


def extract_meson_args(project_path: str) -> list:
    """Extract build args from meson_options.txt."""
    args = [
        {'name': 'prefix', 'default': '/usr/local'},
        {'name': 'buildtype', 'default': 'debugoptimized'},
    ]
    options_file = os.path.join(project_path, 'meson_options.txt')
    if os.path.exists(options_file):
        with open(options_file, 'r', encoding='utf-8') as f:
            content = f.read()
        # Parse option('name', type: ..., value: ...) patterns
        for m in re.finditer(r"option\s*\(\s*'(\w+)'.*?value\s*:\s*'([^']*)'", content, re.DOTALL):
            name = m.group(1)
            value = m.group(2)
            # Check if any of our common args match
            for arg in args:
                if arg['name'] == name:
                    arg['default'] = value
    return args


def extract_make_args(project_path: str) -> list:
    """Extract build args from Makefile."""
    args = [
        {'name': 'prefix', 'default': '/usr/local'},
        {'name': 'DESTDIR', 'default': ''},
    ]
    for makefile in ['Makefile', 'GNUmakefile', 'makefile']:
        mf_path = os.path.join(project_path, makefile)
        if os.path.exists(mf_path):
            with open(mf_path, 'r', encoding='utf-8') as f:
                content = f.read()
            for arg in args:
                m = re.search(
                    r'^' + re.escape(arg['name']) + r'\s*[:\?]?=\s*(.*)$',
                    content, re.MULTILINE
                )
                if m:
                    val = m.group(1).strip()
                    if val:
                        arg['default'] = val
            break
    return args


def extract_autotools_args(project_path: str) -> list:
    """Extract build args from configure script."""
    return [
        {'name': 'prefix', 'default': '/usr/local'},
        {'name': 'host', 'default': ''},
    ]


def extract_args(project_path: str, tool_type: str) -> list:
    """Dispatch to the appropriate extractor based on tool type."""
    extractors = {
        'cmake': extract_cmake_args,
        'meson': extract_meson_args,
        'make': extract_make_args,
        'autotools': extract_autotools_args,
    }
    extractor = extractors.get(tool_type)
    if extractor:
        return extractor(project_path)
    return []


def main():
    if len(sys.argv) < 3:
        print("用法: python3 extract-build-args.py <project_path> <tool_type>", file=sys.stderr)
        sys.exit(1)

    project_path = sys.argv[1]
    tool_type = sys.argv[2]

    build_args = extract_args(project_path, tool_type)
    result = {
        'build_tool': tool_type,
        'build_tool_type': tool_type,
        'build_args': build_args,
    }
    print(yaml.dump(result, default_flow_style=False, allow_unicode=True, sort_keys=False))


if __name__ == '__main__':
    main()