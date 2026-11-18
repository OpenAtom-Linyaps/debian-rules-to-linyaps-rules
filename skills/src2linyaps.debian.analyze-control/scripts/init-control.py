#!/usr/bin/env python3
"""
init-control.py — 完整初始化 YAML：解析 debian/control + 基于 apt 仓库解析运行时依赖。

合并 parse-control.py 与 resolve-runtime-deps.py 为一步调用，
从 debian/control 文件直接生成含 buildDepends + runtimeDepends 的结构化 YAML。

用法:
    python3 init-control.py <control_file_path> [--blacklist <blacklist_json_path>]

输出 (stdout, YAML格式):
    pkgName, pkgDescription, buildDepends[], buildDependsAlternatives[][],
    binaryPackages[], runtimeDepends[]
"""

import sys
import os
import subprocess
import tempfile
import yaml

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

from depends import package_exists  # noqa: E402 同目录依赖解析模块

PARSE_CONTROL = os.path.join(SCRIPT_DIR, "parse-control.py")
RESOLVE_RUNTIME = os.path.join(SCRIPT_DIR, "resolve-runtime-deps.py")


def run_parse_control(control_file: str) -> dict:
    result = subprocess.run(
        ["python3", PARSE_CONTROL, control_file],
        capture_output=True,
        text=True,
        timeout=30,
    )
    if result.returncode != 0:
        print(f"ERROR: parse-control.py 执行失败:\n{result.stderr}", file=sys.stderr)
        sys.exit(1)
    try:
        return yaml.safe_load(result.stdout) or {}
    except yaml.YAMLError as e:
        print(f"ERROR: parse-control.py 输出 YAML 解析失败: {e}", file=sys.stderr)
        sys.exit(1)


def run_resolve_runtime(control_info: dict, blacklist_path: str = None) -> list:
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".yaml", delete=False, encoding="utf-8"
    ) as f:
        temp_yaml_path = f.name
        yaml.dump(
            control_info,
            f,
            default_flow_style=False,
            allow_unicode=True,
            sort_keys=False,
        )

    try:
        cmd = ["python3", RESOLVE_RUNTIME, temp_yaml_path]
        if blacklist_path:
            cmd.extend(["--blacklist", blacklist_path])

        result = subprocess.run(cmd, capture_output=True, text=True, timeout=600)

        if result.stderr:
            print(result.stderr.strip(), file=sys.stderr)

        if result.returncode != 0:
            print(
                f"WARNING: resolve-runtime-deps.py 执行失败，runtimeDepends 将为空:\n{result.stderr}",
                file=sys.stderr,
            )
            return []

        runtime_info = yaml.safe_load(result.stdout) or {}
        return runtime_info.get("runtimeDepends", [])
    finally:
        os.unlink(temp_yaml_path)


def verify_runtime_deps(runtime_depends: list) -> list:
    if not runtime_depends:
        return []
    available = []
    missing = []
    for pkg in runtime_depends:
        if package_exists(pkg):
            available.append(pkg)
        else:
            missing.append(pkg)
    if missing:
        print(
            f"WARNING: 以下 {len(missing)} 个运行时依赖在当前 apt 仓库不可用，已自动过滤: {missing}",
            file=sys.stderr,
        )
    return available


def main():
    if len(sys.argv) < 2:
        print(
            f"用法: python3 {os.path.basename(__file__)} <control_file_path> "
            "[--blacklist <blacklist_json_path>]",
            file=sys.stderr,
        )
        sys.exit(1)

    control_file = sys.argv[1]
    blacklist_path = None
    if len(sys.argv) >= 4 and sys.argv[2] == "--blacklist":
        blacklist_path = sys.argv[3]

    control_info = run_parse_control(control_file)
    runtime_depends = run_resolve_runtime(control_info, blacklist_path)
    runtime_depends = verify_runtime_deps(runtime_depends)
    control_info["runtimeDepends"] = runtime_depends

    print(
        yaml.dump(
            control_info, default_flow_style=False, allow_unicode=True, sort_keys=False
        )
    )


if __name__ == "__main__":
    main()
