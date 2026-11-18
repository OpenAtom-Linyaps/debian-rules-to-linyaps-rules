#!/usr/bin/env python3
"""
scan-patches.py — 扫描 debian/patches/series，识别激活/禁用补丁。

用法:
    python3 scan-patches.py <debian_path>

输出 (stdout, YAML格式):
    active: list[str]       激活补丁文件名（相对 debian/patches/，按 series 顺序）
    disabled: list[str]     被 # 注释掉的补丁文件名
    missing: list[str]      series 中引用但 debian/patches/ 下不存在的补丁名
    source_format: str      如 '3.0 (quilt)' 或 '3.0 (native)'，文件不存在为 ''
    has_patches: bool       是否存在补丁
"""

import sys
import os
import yaml


def scan_patches(debian_path: str) -> dict:
    """扫描 debian/patches/series，识别激活/禁用补丁。

    返回 dict:
      - active: list[str]  激活补丁文件名（相对 debian/patches/，按 series 顺序）
      - disabled: list[str]  被 # 注释掉的补丁文件名
      - missing: list[str]  series 中引用但 debian/patches/ 下不存在的补丁名
      - source_format: str  如 '3.0 (quilt)' 或 '3.0 (native)'，文件不存在为 ''
      - has_patches: bool  是否存在补丁
    """
    active = []
    disabled = []
    missing = []
    source_format = ""

    # 1. 读 debian/source/format
    format_path = os.path.join(debian_path, "source", "format")
    if os.path.isfile(format_path):
        with open(format_path, "r", encoding="utf-8") as f:
            format_content = f.read().strip()
        if "3.0 (quilt)" in format_content:
            source_format = "3.0 (quilt)"
        elif "3.0 (native)" in format_content:
            source_format = "3.0 (native)"
            # native 包不用 quilt，补丁不存在
            return {
                "active": [],
                "disabled": [],
                "missing": [],
                "source_format": source_format,
                "has_patches": False,
            }
        else:
            source_format = format_content

    # 2. 读 debian/patches/series
    series_path = os.path.join(debian_path, "patches", "series")
    if not os.path.isfile(series_path):
        return {
            "active": [],
            "disabled": [],
            "missing": [],
            "source_format": source_format,
            "has_patches": False,
        }

    # 3. 逐行解析 series
    with open(series_path, "r", encoding="utf-8") as f:
        for line in f:
            stripped = line.rstrip("\n")
            if not stripped.strip():
                # 空行跳过
                continue
            if stripped.lstrip().startswith("#"):
                # 行首 # 注释 → 取 # 后去空格的文件名加入 disabled
                comment_part = stripped.lstrip()[1:].strip()
                if comment_part:
                    disabled.append(comment_part)
            else:
                # 非空行 → 截取行内 # 前部分去空格加入 active
                hash_pos = stripped.find("#")
                if hash_pos >= 0:
                    patch_name = stripped[:hash_pos].strip()
                else:
                    patch_name = stripped.strip()
                if patch_name:
                    active.append(patch_name)

    # 4. 检查 active 中每个补丁是否存在
    patches_dir = os.path.join(debian_path, "patches")
    still_active = []
    for name in active:
        patch_path = os.path.join(patches_dir, name)
        if os.path.isfile(patch_path):
            still_active.append(name)
        else:
            missing.append(name)
    active = still_active

    # 5. has_patches
    has_patches = len(active) > 0 or len(disabled) > 0

    return {
        "active": active,
        "disabled": disabled,
        "missing": missing,
        "source_format": source_format,
        "has_patches": has_patches,
    }


def main():
    if len(sys.argv) < 2:
        print("用法: python3 scan-patches.py <debian_path>", file=sys.stderr)
        sys.exit(1)
    debian_path = sys.argv[1]
    result = scan_patches(debian_path)
    print(
        yaml.dump(result, default_flow_style=False, allow_unicode=True, sort_keys=False)
    )


if __name__ == "__main__":
    main()
