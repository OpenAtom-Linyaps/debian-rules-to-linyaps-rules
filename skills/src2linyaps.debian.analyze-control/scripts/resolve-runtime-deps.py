#!/usr/bin/env python3
"""
resolve-runtime-deps.py — 基于 apt 仓库解析构建依赖的运行时依赖。

从 parse-control.py 输出的 YAML 中读取 buildDepends 列表，
逐包调用 apt-cache depends 查询运行时 Depends 和 Recommends，
去重后输出 runtimeDepends 列表。

支持 --blacklist 参数，用于过滤不应写入 runtimeDepends 的包（如编译器、Mesa 驱动等）。

用法:
    python3 resolve-runtime-deps.py <control_yaml_path> [--blacklist <blacklist_json_path>]

输出 (stdout, YAML格式):
    runtimeDepends:
      - libc6
      - libcurl4
      - ...
"""

import sys
import os
import json
import re
import subprocess
import yaml


MAX_RECURSE_DEPTH = 3

# 包名后缀黑名单 — 这些包不应进入运行时依赖
RUNTIME_EXCLUDED_SUFFIXES = ('-dev', '-dbgsym', '-dbg', '-doc')


def strip_version(pkg: str) -> str:
    """从带版本约束和构建 profile 的依赖字符串中提取裸包名。

    'cmake (>= 3.16~)'   → 'cmake'
    'xauth <!nocheck>'   → 'xauth'
    'libc6:amd64'        → 'libc6'
    """
    pkg = pkg.strip()
    pkg = re.sub(r'\s*\([^)]*\)', '', pkg).strip()
    pkg = re.sub(r'\s*<![^>]+>', '', pkg).strip()
    pkg = re.sub(r':\w+$', '', pkg).strip()
    return pkg


def is_runtime_package(pkg: str) -> bool:
    """判断包名是否属于不应进入 runtimeDepends 的类别。

    过滤规则：以 -dev / -dbgsym / -dbg / -doc 结尾的包名。
    """
    return pkg.endswith(RUNTIME_EXCLUDED_SUFFIXES)


def query_apt_depends(pkg: str, include_recommends: bool = True) -> list:
    """对单个包调用 apt-cache depends，返回 Depends 列表。

    include_recommends=True 时同时提取 Recommends（第一层用），
    include_recommends=False 时只提取 Depends（递归层用）。
    """
    try:
        result = subprocess.run(
            ['apt-cache', 'depends', pkg],
            capture_output=True, text=True,
            env={'LC_ALL': 'C'},
            timeout=30,
        )
    except FileNotFoundError:
        print(f"WARNING: apt-cache 命令未找到，无法查询 {pkg}", file=sys.stderr)
        return []
    except subprocess.TimeoutExpired:
        print(f"WARNING: 查询 {pkg} 超时", file=sys.stderr)
        return []

    if result.returncode != 0:
        if 'Unable to locate package' in result.stderr or \
           '没有发现匹配' in result.stderr:
            print(f"WARNING: 未找到包 {pkg}，跳过", file=sys.stderr)
        else:
            print(f"WARNING: 查询 {pkg} 失败: {result.stderr.strip()}", file=sys.stderr)
        return []

    dep_types = ['Depends']
    if include_recommends:
        dep_types.append('Recommends')
    pattern = r'^  (' + '|'.join(dep_types) + r'):\s+(.+)'

    deps = []
    for line in result.stdout.splitlines():
        line_stripped = line.strip()
        if not line_stripped or line_stripped.startswith('<') or line_stripped.endswith('>'):
            continue
        if not line.startswith('  '):
            continue
        m = re.match(pattern, line)
        if m:
            dep_pkg = m.group(2).strip()
            if dep_pkg.startswith('<'):
                continue
            deps.append(dep_pkg)
    return deps


def _resolve_recursive(
    pkg: str,
    seen: set,
    runtime_deps: list,
    runtime_deps_set: set,
    blacklist: set,
    depth: int,
) -> None:
    """递归解析单包的 Depends（仅 Depends，不含 Recommends）。

    递归终止条件：
    - depth > MAX_RECURSE_DEPTH
    - pkg 已在 seen 中（已查询过）
    """
    if depth > MAX_RECURSE_DEPTH or pkg in seen:
        return
    seen.add(pkg)

    sub_deps = query_apt_depends(pkg, include_recommends=False)
    for d_raw in sub_deps:
        d = d_raw.strip()
        if not d or d in blacklist or is_runtime_package(d):
            continue
        if d not in runtime_deps_set:
            runtime_deps.append(d)
            runtime_deps_set.add(d)
        _resolve_recursive(d, seen, runtime_deps, runtime_deps_set, blacklist, depth + 1)


def resolve_runtime_depends(build_depends: list, blacklist: set = None) -> list:
    """解析所有 Build-Depends 包的运行时依赖，BFS 递归至多 3 层。

    - 第一层：对每个 Build-Depends 包查询 Depends + Recommends
    - 第 2~3 层：对每个命中包查询 Depends（不含 Recommends）
    - 过滤 -dev/-dbgsym/-dbg/-doc 包
    - 黑名单包不进入结果
    - 全局 seen 缓存避免重复查询

    blacklist: 需要从结果中排除的包名集合。
    """
    if blacklist is None:
        blacklist = set()

    seen = set()
    runtime_deps = []
    runtime_deps_set = set()

    for dep in build_depends:
        pkg = strip_version(dep)
        if not pkg or pkg in seen:
            continue
        seen.add(pkg)

        first_deps = query_apt_depends(pkg, include_recommends=True)
        for d_raw in first_deps:
            d = d_raw.strip()
            if not d or d in blacklist or is_runtime_package(d):
                continue
            if d not in runtime_deps_set:
                runtime_deps.append(d)
                runtime_deps_set.add(d)
            _resolve_recursive(d, seen, runtime_deps, runtime_deps_set, blacklist, depth=1)

    return sorted(runtime_deps)


def load_blacklist(path: str) -> set:
    """从 JSON 文件加载黑名单包名集合。文件不存在时给出警告并返回空集合。"""
    if not path or not os.path.isfile(path):
        if path:
            print(f"WARNING: 黑名单文件不存在: {path}，跳过过滤", file=sys.stderr)
        return set()
    try:
        with open(path, 'r', encoding='utf-8') as f:
            data = json.load(f)
        if not isinstance(data, list):
            print(f"WARNING: 黑名单文件 {path} 格式错误（需要 JSON 数组），跳过过滤", file=sys.stderr)
            return set()
        return set(data)
    except (json.JSONDecodeError, IOError) as e:
        print(f"WARNING: 读取黑名单文件失败 {path}: {e}，跳过过滤", file=sys.stderr)
        return set()


def main():
    if len(sys.argv) < 2:
        print("用法: python3 resolve-runtime-deps.py <control_yaml_path> [--blacklist <blacklist_json_path>]", file=sys.stderr)
        sys.exit(1)

    # 解析参数
    yaml_path = sys.argv[1]
    blacklist_path = None
    if len(sys.argv) >= 4 and sys.argv[2] == '--blacklist':
        blacklist_path = sys.argv[3]

    blacklist = load_blacklist(blacklist_path)
    if blacklist:
        print(f"INFO: 已加载 {len(blacklist)} 个黑名单包名", file=sys.stderr)

    try:
        with open(yaml_path, 'r', encoding='utf-8') as f:
            control_info = yaml.safe_load(f)
    except FileNotFoundError:
        print(f"ERROR: 文件不存在: {yaml_path}", file=sys.stderr)
        sys.exit(1)
    except yaml.YAMLError as e:
        print(f"ERROR: YAML 解析失败: {e}", file=sys.stderr)
        sys.exit(1)

    build_depends = control_info.get('buildDepends', [])
    if not build_depends:
        print("WARNING: control YAML 中 buildDepends 为空", file=sys.stderr)
        print(yaml.dump({'runtimeDepends': []}, default_flow_style=False, allow_unicode=True, sort_keys=False))
        return

    runtime_deps = resolve_runtime_depends(build_depends, blacklist)
    result = {'runtimeDepends': runtime_deps}
    print(yaml.dump(result, default_flow_style=False, allow_unicode=True, sort_keys=False))


if __name__ == '__main__':
    main()