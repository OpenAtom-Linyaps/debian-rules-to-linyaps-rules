"""package_exists() — 基于 apt 仓库的软件包存在性探测（Issue 55）。

对单个包调用 `apt-cache show <pkg>`，返回非 0 即判为「当前 apt 仓库中不存在」。

必须逐包调用，不能一次性聚合 `apt-cache show pkgA pkgB ...`：
聚合调用在「部分缺失」时返回 0 且无 stderr（缺失包被静默丢弃），
是历史 issue-55 存在性校验失效的根源。

本模块归属 src2linyaps.debian.analyze-control（依赖解析同源）。其他 skill 需要
存在性校验时，由 Agent/SKILL 调用本 skill，而非跨 skill 直接 import。
"""

import subprocess
import sys


def package_exists(pkg: str) -> bool:
    """独立校验 pkg 是否存在于当前 apt 仓库。返回码非 0 视为不存在。

    兼容本地化错误文案（如 `E: 没有发现匹配的软件包`），不依赖英文正则。
    """
    if not pkg:
        return False
    try:
        result = subprocess.run(
            ['apt-cache', 'show', pkg],
            capture_output=True, text=True,
            env={'LC_ALL': 'C'},
            timeout=30,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        print(f"WARNING: 校验 {pkg} 存在性失败，按不可用处理: {e}", file=sys.stderr)
        return False
    if result.returncode != 0:
        print(f"WARNING: 包 {pkg} 在当前 apt 仓库中不存在，已剔除", file=sys.stderr)
        return False
    return True


def split_available_missing(pkgs: list) -> tuple:
    """对列表逐包探测，返回 (available, missing) 两组。"""
    available = []
    missing = []
    for pkg in pkgs:
        if package_exists(pkg):
            available.append(pkg)
        else:
            missing.append(pkg)
    return available, missing