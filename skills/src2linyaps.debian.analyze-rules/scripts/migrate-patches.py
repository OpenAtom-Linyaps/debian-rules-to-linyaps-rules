#!/usr/bin/env python3
"""
migrate-patches.py — 补丁迁移核心脚本。

在合并的 Debian+源码构建工作目录中用 quilt 尝试应用补丁，
对失败补丁捕获 reject 内容供 LLM 修复，验证通过的补丁复制到
CI_ll_<package_id>/patches/（与 linglong.yaml 同级），生成 patch -p1 命令字符串注入 build: 段。

用法:
    python3 migrate-patches.py \
        --project-path <project_path> \
        --debian-path <debian_path> \
        --build-tmp-dir <build_tmp_dir> \
        --source-name <source_name> \
        --package-id <package_id> \
        --target-yaml <target_linglong.yaml> \
        [--source-patches-dir <debian_patches_dir>] \
        [--patches-dir <host_output_patches_dir>] \
        [--retry]

输出 (stdout, YAML格式):
    has_patches: bool
    source_format: str
    patches_applied: list[str]
    patches_failed: list[dict]   # {name, error, rej_content}
    patches_disabled: list[str]
    patch_commands: str          # 可直接前置注入 build_section
    patches_dir: str             # <target_yaml_dir>/patches（与 linglong.yaml 同级，或 --patches-dir 显式指定）
"""

import argparse
import sys
import os
import re
import shutil
import subprocess
import yaml

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SCAN_PATCHES = os.path.join(SCRIPT_DIR, "scan-patches.py")

# 容器内补丁目录路径（可配置）
LINGLONG_PATCHES_DIR = "/project/linglong/patches"
# 容器内源码目录前缀
LINGLONG_SOURCES_DIR = "/project/linglong/sources"


def get_patch_info(debian_path: str) -> dict:
    """subprocess 调用 scan-patches.py，返回解析后的 dict。"""
    result = subprocess.run(
        ["python3", SCAN_PATCHES, debian_path],
        capture_output=True,
        text=True,
        timeout=30,
    )
    if result.returncode != 0:
        print(f"ERROR: scan-patches.py 执行失败:\n{result.stderr}", file=sys.stderr)
        return {
            "has_patches": False,
            "active": [],
            "disabled": [],
            "missing": [],
            "source_format": "",
        }
    try:
        return yaml.safe_load(result.stdout) or {}
    except yaml.YAMLError as e:
        print(f"ERROR: scan-patches.py 输出 YAML 解析失败: {e}", file=sys.stderr)
        return {
            "has_patches": False,
            "active": [],
            "disabled": [],
            "missing": [],
            "source_format": "",
        }


def check_quilt_available() -> bool:
    """检查 quilt 是否可用。"""
    try:
        result = subprocess.run(
            ["which", "quilt"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        return result.returncode == 0
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return False


def create_merged_workdir(
    project_path: str,
    debian_path: str,
    build_tmp_dir: str,
    package_id: str,
    retry: bool = False,
) -> str:
    """在 build_tmp_dir 创建合并的源码+debian 工作目录。

    返回工作目录路径。
    retry 模式下不清理旧目录（保留已应用状态）。
    """
    workdir = os.path.join(build_tmp_dir, f"{package_id}-patch-merge")
    if not retry:
        shutil.rmtree(workdir, ignore_errors=True)
        try:
            shutil.copytree(project_path, workdir, dirs_exist_ok=True)
            shutil.copytree(
                debian_path, os.path.join(workdir, "debian"), dirs_exist_ok=True
            )
        except (OSError, shutil.Error) as e:
            print(f"ERROR: 创建合并工作目录失败: {e}", file=sys.stderr)
            return ""
    else:
        # retry 模式：仅同步补丁文件（LLM 可能已修改）
        patches_src = os.path.join(debian_path, "patches")
        patches_dst = os.path.join(workdir, "debian", "patches")
        if os.path.isdir(patches_src) and os.path.isdir(patches_dst):
            for name in os.listdir(patches_src):
                src_file = os.path.join(patches_src, name)
                dst_file = os.path.join(patches_dst, name)
                if os.path.isfile(src_file):
                    shutil.copy2(src_file, dst_file)
    return workdir


def quilt_apply_all(workdir: str) -> dict:
    """在合并工作目录运行 quilt push -a。

    返回:
      - applied: list[str]  成功应用的补丁名
      - failed: list[dict]  {name, error, rej_content}
      - all_patches: list[str]  series 中全部补丁
    """
    env = {**os.environ, "QUILT_PATCHES": "debian/patches"}

    # 获取 series 中全部补丁
    all_patches = []
    series_file = os.path.join(workdir, "debian", "patches", "series")
    if os.path.isfile(series_file):
        with open(series_file, "r", encoding="utf-8") as f:
            for line in f:
                stripped = line.strip()
                if stripped and not stripped.startswith("#"):
                    all_patches.append(stripped)

    # 尝试 quilt push -a（--leave-rejects 保留 .rej 文件供 LLM 诊断）
    push_result = subprocess.run(
        ["quilt", "push", "-a", "--leave-rejects"],
        cwd=workdir,
        env=env,
        capture_output=True,
        text=True,
        timeout=120,
    )

    # 获取已应用的补丁列表
    applied_result = subprocess.run(
        ["quilt", "applied"],
        cwd=workdir,
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )
    applied = []
    for line in applied_result.stdout.strip().splitlines():
        name = line.strip()
        if not name:
            continue
        # quilt applied 可能返回相对 QUILT_PATCHES 的路径（如 debian/patches/xxx.patch）
        # 归一化为 series 中的文件名（去掉目录前缀）
        if name.startswith("debian/patches/"):
            name = name[len("debian/patches/") :]
        applied.append(name)

    # 计算失败的补丁
    applied_set = set(applied)
    failed = []
    for patch in all_patches:
        if patch not in applied_set:
            # quilt 错误信息输出到 stdout（非 stderr）
            error_msg = (
                push_result.stdout.strip() if push_result.returncode != 0 else ""
            )
            # 查找 .rej 文件 — quilt --leave-rejects 在被补丁的源文件旁生成 .rej
            rej_content = ""
            for root, dirs, files in os.walk(workdir):
                # 跳过 debian 目录和 .pc 目录中的 .rej（不相关）
                parts = root.split(os.sep)
                if "debian" in parts or ".pc" in parts:
                    continue
                for fname in files:
                    if fname.endswith(".rej"):
                        rej_path = os.path.join(root, fname)
                        try:
                            with open(
                                rej_path, "r", encoding="utf-8", errors="replace"
                            ) as rf:
                                rej_content = rf.read()
                            break
                        except OSError:
                            pass
                if rej_content:
                    break

            failed.append(
                {
                    "name": patch,
                    "error": error_msg,
                    "rej_content": rej_content,
                }
            )

    return {
        "applied": applied,
        "failed": failed,
        "all_patches": all_patches,
    }


def copy_patches(
    source_patches_dir: str, applied_patches: list, output_patches_dir: str
) -> None:
    """将验证通过的补丁文件复制到 CI_ll_<package_id>/patches/。"""
    os.makedirs(output_patches_dir, exist_ok=True)
    for name in applied_patches:
        src = os.path.join(source_patches_dir, name)
        dst = os.path.join(output_patches_dir, name)
        # 若 name 含子目录，保留目录结构
        parent = os.path.dirname(dst)
        if parent:
            os.makedirs(parent, exist_ok=True)
        if os.path.isfile(src):
            shutil.copy2(src, dst)


def generate_patch_commands(applied_patches: list, source_name: str) -> str:
    """生成 build: 段的 shell 命令字符串。

    输出（逐行）:
      export SRC_ROOT=$(ls -d /project/linglong/sources/<source_name>/*)
      cd ${SRC_ROOT}
      patch -p1 < /project/linglong/patches/<patch1>
      patch -p1 < /project/linglong/patches/<patch2>

    使用 SRC_ROOT 变量进入源码目录，与 linglong 源码进入约定一致
    （参照 update-linglong-yaml.py build_cd_command()：archive/git/dsc 源码类型
    统一 `export SRC_ROOT=$(ls -d /project/linglong/sources/<name>/*); cd ${SRC_ROOT}`）。
    使用显式逐文件 patch 命令（非 glob）以保留 series 顺序。
    applied_patches 为空 → 返回空字符串。
    """
    if not applied_patches:
        return ""
    lines = [
        f"export SRC_ROOT=$(ls -d {LINGLONG_SOURCES_DIR}/{source_name}/*)",
        "cd ${SRC_ROOT}",
    ]
    for patch_name in applied_patches:
        lines.append(f"patch -p1 < {LINGLONG_PATCHES_DIR}/{patch_name}")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(
        description="补丁迁移核心脚本：用 quilt 应用补丁，验证后复制到输出目录并生成 patch 命令。",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--project-path", required=True, help="项目源码根目录路径")
    parser.add_argument("--debian-path", required=True, help="debian/ 目录路径")
    parser.add_argument(
        "--build-tmp-dir", required=True, help="构建临时目录（用于创建合并工作目录）"
    )
    parser.add_argument(
        "--source-name",
        required=True,
        help="源码目录名（用于生成 export SRC_ROOT=$(ls -d /project/linglong/sources/<source_name>/*) 的源码路径）",
    )
    parser.add_argument(
        "--package-id",
        required=True,
        help="包标识符（用于 CI_ll_<package_id> 目录命名）",
    )
    parser.add_argument(
        "--target-yaml",
        required=True,
        help="目标 linglong.yaml 路径（补丁输出目录从其父目录推导）",
    )
    parser.add_argument(
        "--source-patches-dir",
        default=None,
        help="源 Debian 补丁目录（默认 <debian_path>/patches）",
    )
    parser.add_argument(
        "--patches-dir",
        default=None,
        help="补丁输出目录（默认 <target_yaml_dir>/patches，与 linglong.yaml 同级）",
    )
    parser.add_argument(
        "--retry",
        action="store_true",
        help="重试模式：不清理旧工作目录，仅同步补丁文件",
    )
    args = parser.parse_args()

    project_path = args.project_path
    debian_path = args.debian_path
    build_tmp_dir = args.build_tmp_dir
    source_name = args.source_name
    package_id = args.package_id
    retry = args.retry

    # 源补丁目录：显式指定或从 debian_path 推导
    source_patches_dir = args.source_patches_dir or os.path.join(debian_path, "patches")

    # 补丁输出目录：显式指定或从 --target-yaml 父目录推导
    # target-yaml 通常为 <output_dir>/CI_ll_<package_id>/linglong.yaml，
    # 补丁与其同级 → <target_yaml_dir>/patches/
    if args.patches_dir:
        output_patches_dir = args.patches_dir
    else:
        target_yaml_dir = os.path.dirname(os.path.abspath(args.target_yaml))
        output_patches_dir = os.path.join(target_yaml_dir, "patches")

    # 获取补丁信息
    patch_info = get_patch_info(debian_path)

    # 无补丁 → 输出空结果，exit 0
    if not patch_info.get("has_patches", False):
        result = {
            "has_patches": False,
            "source_format": patch_info.get("source_format", ""),
            "patches_applied": [],
            "patches_failed": [],
            "patches_disabled": patch_info.get("disabled", []),
            "patch_commands": "",
            "patches_dir": "",
        }
        print(
            yaml.dump(
                result, default_flow_style=False, allow_unicode=True, sort_keys=False
            )
        )
        return

    # 检查 quilt 可用性
    if not check_quilt_available():
        result = {
            "has_patches": False,
            "source_format": patch_info.get("source_format", ""),
            "patches_applied": [],
            "patches_failed": [],
            "patches_disabled": patch_info.get("disabled", []),
            "patch_commands": "",
            "patches_dir": "",
            "error": "quilt not found",
        }
        print(
            yaml.dump(
                result, default_flow_style=False, allow_unicode=True, sort_keys=False
            )
        )
        return

    # 创建合并工作目录
    workdir = create_merged_workdir(
        project_path, debian_path, build_tmp_dir, package_id, retry=retry
    )
    if not workdir:
        result = {
            "has_patches": False,
            "source_format": patch_info.get("source_format", ""),
            "patches_applied": [],
            "patches_failed": [],
            "patches_disabled": patch_info.get("disabled", []),
            "patch_commands": "",
            "patches_dir": "",
            "error": "failed to create merged workdir",
        }
        print(
            yaml.dump(
                result, default_flow_style=False, allow_unicode=True, sort_keys=False
            )
        )
        sys.exit(1)

    # quilt push -a
    quilt_result = quilt_apply_all(workdir)

    # 复制验证通过的补丁
    applied_patches = quilt_result["applied"]
    if applied_patches:
        copy_patches(source_patches_dir, applied_patches, output_patches_dir)

    # 生成 patch 命令
    patch_commands = generate_patch_commands(applied_patches, source_name)

    # 输出结果
    result = {
        "has_patches": True,
        "source_format": patch_info.get("source_format", ""),
        "patches_applied": applied_patches,
        "patches_failed": quilt_result["failed"],
        "patches_disabled": patch_info.get("disabled", []),
        "patch_commands": patch_commands,
        "patches_dir": output_patches_dir if applied_patches else "",
    }
    print(
        yaml.dump(result, default_flow_style=False, allow_unicode=True, sort_keys=False)
    )


if __name__ == "__main__":
    main()
