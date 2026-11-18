# 补丁迁移方案 — `src2linyaps.debian.analyze-rules`

## 背景

为 `src2linyaps.debian.analyze-rules` 技能新增补丁迁移能力。工作流：扫描 Debian 已激活补丁（`debian/patches/series`）→ 在合并的 Debian+源码构建工作目录中用 `quilt` 尝试应用补丁 → 对禁用/过期补丁按最新代码修改修复 → 保存 `linglong.yaml`，补丁以 shell 命令形式集成到 `build:` 段。

Linglong 无原生 `patches` 字段（`linglong-schema.yaml` `top_level.allowed` 不含此项，已核实第 19-30 行）。补丁文件复制到 `patches/`（与 `linglong.yaml` 同级），`patch -p1` 命令前置注入 `build:` 字符串。无需改动 schema、校验脚本、默认值配置。

系统已验证可用工具：`quilt 0.68`、`dpkg-source 1.22.6`、`python3 3.12.13`。

**核心约束**：补丁相关全部为新功能，在新代码文件中独立实现，不修改 `analyze-rules.py`。遵循现有 skill 内多脚本协作模式——同目录脚本用 `subprocess.run(['python3', <path>, ...])` 互调（参照 `init-control.py` L31 调用 `parse-control.py`），不跨文件 import。

## 方案步骤（按执行顺序）

### 步骤 1：创建独立的 `scan-patches.py` 脚本（新文件）

**目标文件**：`skills/src2linyaps.debian.analyze-rules/scripts/scan-patches.py`（新建）

**CLI 接口**：
```
python3 scan-patches.py <debian_path>
```

**函数签名**（错误处理风格复用 `analyze-rules.py` 的 `scan_resource_files()` L98——返回结构化 dict，缺失文件返回空列表而非抛异常）：

```python
def scan_patches(debian_path: str) -> dict:
    """扫描 debian/patches/series，识别激活/禁用补丁。

    返回 dict:
      - active: list[str]  激活补丁文件名（相对 debian/patches/，按 series 顺序）
      - disabled: list[str]  被 # 注释掉的补丁文件名
      - missing: list[str]  series 中引用但 debian/patches/ 下不存在的补丁名
      - source_format: str  如 '3.0 (quilt)' 或 '3.0 (native)'，文件不存在为 ''
      - has_patches: bool  是否存在补丁
    """
```

**逻辑**（逐条）：
1. 读 `debian/source/format`；内容含 `3.0 (quilt)` → `source_format='3.0 (quilt)'`；含 `3.0 (native)` → `has_patches=False` 直接返回（native 包不用 quilt，补丁不存在）；文件不存在 → `source_format=''`。
2. 读 `debian/patches/series`：文件不存在 → `has_patches=False`，空列表返回。
3. 逐行解析 series：行首 `#` 开头 → 取 `#` 后去空格的文件名加入 `disabled`；非空行 → 截取行内 `#` 前部分去空格加入 `active`（保留 series 顺序）；空行跳过。
4. 对 `active` 中每个补丁，检查 `debian/patches/<name>` 是否存在；不存在的从 `active` 移除并记入 `missing` 列表。
5. `has_patches = len(active) > 0 or len(disabled) > 0`。

**`main()`**：解析 `sys.argv[1]` 为 `debian_path`，调用 `scan_patches()`，`print(yaml.dump(result, default_flow_style=False, allow_unicode=True, sort_keys=False))` 输出 YAML。

**不修改 `analyze-rules.py`**：`analyze()` 返回 dict 不新增 `patches` 键；补丁扫描完全独立。

### 步骤 2：创建独立的 `migrate-patches.py` 脚本（新文件）

**目标文件**：`skills/src2linyaps.debian.analyze-rules/scripts/migrate-patches.py`（新建）

**CLI 接口**：
```
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
```

`<source_name>`：源码在 linglong 容器中的目录名（如 `deepin-calculator`），用于生成 `export SRC_ROOT=$(ls -d /project/linglong/sources/<source_name>/*); cd ${SRC_ROOT}`。
`<package_id>`：用于 `CI_ll_<package_id>` 工程目录命名。
`--target-yaml`：目标 `linglong.yaml` 路径；补丁输出目录默认从其父目录推导（与 `linglong.yaml` 同级的 `patches/`）。
`--source-patches-dir`：源 Debian 补丁目录（默认 `<debian_path>/patches`）。
`--patches-dir`：补丁输出目录（默认 `<target_yaml_dir>/patches`）。
`--retry`：LLM 修复补丁后重试模式，跳过已成功补丁，仅重试之前失败的。

**获取补丁信息**（subprocess 调用 `scan-patches.py`，参照 `init-control.py` L31 调 `parse-control.py` 的模式）：
```python
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SCAN_PATCHES = os.path.join(SCRIPT_DIR, 'scan-patches.py')

def get_patch_info(debian_path: str) -> dict:
    """subprocess 调用 scan-patches.py，返回解析后的 dict。"""
    result = subprocess.run(
        ['python3', SCAN_PATCHES, debian_path],
        capture_output=True, text=True, timeout=30,
    )
    return yaml.safe_load(result.stdout)
```
不 import `analyze-rules.py` 也不 import `scan-patches.py`——纯 subprocess 调用，符合现有 skill 内脚本协作模式。

**函数定义**（逐个签名+逻辑）：

```python
def create_merged_workdir(project_path: str, debian_path: str,
                          build_tmp_dir: str, package_id: str) -> str:
    """在 build_tmp_dir 创建合并的源码+debian 工作目录。
    返回工作目录路径。
    1. workdir = os.path.join(build_tmp_dir, f'{package_id}-patch-merge')
    2. shutil.rmtree(workdir, ignore_errors=True)  # 清理旧目录
    3. shutil.copytree(project_path, workdir, dirs_exist_ok=True)
    4. shutil.copytree(debian_path, os.path.join(workdir, 'debian'), dirs_exist_ok=True)
    5. return workdir
    错误处理：copytree 失败 → 输出 {error: ..., has_patches: false} 并 exit 1
    """
```

```python
def quilt_apply_all(workdir: str) -> dict:
    """在合并工作目录运行 quilt push -a。
    返回:
      - applied: list[str]  成功应用的补丁名
      - failed: list[dict]  {name, error, rej_content}
      - all_patches: list[str]  series 中全部补丁
    1. env = {**os.environ, 'QUILT_PATCHES': 'debian/patches'}
    2. subprocess.run(['quilt', 'series'], cwd=workdir, env=env, capture_output=True)
       → 解析 stdout 得 all_patches
    3. subprocess.run(['quilt', 'push', '-a'], cwd=workdir, env=env,
                      capture_output=True, text=True)
       → 退出码 0：全部成功
       → 退出码非 0：解析 stderr 定位失败补丁名（stderr 含 'Patch failed at <name>'）
    4. subprocess.run(['quilt', 'applied'], cwd=workdir, env=env, capture_output=True)
       → 解析 stdout 得 applied 列表
    5. all_patches - applied = failed；对每个 failed 补丁，读 workdir 下对应 .rej 文件
       (路径: <被补丁的源文件路径>.rej) → rej_content
    """
```

```python
def copy_patches(source_patches_dir: str, applied_patches: list,
                 output_patches_dir: str) -> None:
    """将验证通过的补丁文件复制到 patches/（与 linglong.yaml 同级）。
    1. os.makedirs(output_patches_dir, exist_ok=True)
    2. 对 applied_patches 中每个补丁：
       src = os.path.join(source_patches_dir, name)
       dst = os.path.join(output_patches_dir, name)
       若 name 含子目录（如 debian/foo/0001.patch），保留目录结构（os.makedirs 父目录）
       shutil.copy2(src, dst)
    """
```

```python
def generate_patch_commands(applied_patches: list, source_name: str) -> str:
    """生成 build: 段的 shell 命令字符串。
    输出（逐行）:
      export SRC_ROOT=$(ls -d /project/linglong/sources/<source_name>/*)
      cd ${SRC_ROOT}
      patch -p1 < /project/linglong/patches/<patch1>
      patch -p1 < /project/linglong/patches/<patch2>
    使用 SRC_ROOT 变量进入源码目录，与 linglong 源码进入约定一致
    （参照 update-linglong-yaml.py build_cd_command()）。
    使用显式逐文件命令（非 glob）以保留 series 顺序。
    applied_patches 为空 → 返回空字符串。
    """
```

```python
def main():
    """编排: get_patch_info → (has_patches? skip : create_merged_workdir → quilt_apply
    → copy_patches → generate_patch_commands)。
    输出 YAML 到 stdout:
      has_patches: bool
      source_format: str
      patches_applied: list[str]
      patches_failed: list[dict]  # {name, error, rej_content}
      patches_disabled: list[str]
      patch_commands: str  # 可直接前置注入 build_section
      patches_dir: str  # <target_yaml_dir>/patches（与 linglong.yaml 同级）
    has_patches 为 false → 输出 {has_patches: false, patch_commands: ''}，exit 0
    --retry 模式: 跳过 create_merged_workdir 中的 rmtree（保留已应用状态），
      仅对 failed 补丁重新 quilt push。
    """
```

### 步骤 3：`for-multica/agent.md` 新增 A3.3 步骤

**目标文件**：`for-multica/agent.md`
**插入位置**：A3 段（第 48 行）之后、A4 段（第 49 行）之前。

**新增内容**（在 A3 段末尾之后、`**A4**` 之前插入）：

```markdown
**A3.3** 补丁迁移（仅当 `debian/patches/series` 存在且含激活补丁时执行）：
  a. 执行 `skills/src2linyaps.debian.analyze-rules/scripts/migrate-patches.py --project-path <project_path> --debian-path <debian_path> --build-tmp-dir <build_tmp_dir> --source-name <source_name> --package-id <package_id> --target-yaml <target_linglong.yaml>` → stdout YAML 含 `patches_applied`/`patches_failed`/`patch_commands`/`patches_dir`/`has_patches`（`--source-patches-dir`/`--patches-dir` 可选，默认从 `--debian-path/patches` 与 `--target-yaml` 父目录推导）
  b. `has_patches: false`（无 series、series 为空、native 包）→ 跳过 A3.3，build_section 不变，不影响后续流程
  c. `patches_failed` 非空 → LLM 读取 `patches_failed[].rej_content` 与 `patches_failed[].error`，按当前源码修改对应补丁文件（调整行号、更新上下文、拆分/合并 hunk），重跑 `migrate-patches.py --retry`
  d. 仍失败 → 跳过该补丁，记 `patch_skipped, <package_id>, <patch_name>` 警告，继续迁移其余补丁（非阻断）
  e. 将 `patch_commands` 前置注入 A3.2 输出的 `build_section`（`patch_commands + "\n" + build_section`）
  f. 验证通过的补丁文件已由脚本复制到 `<target_yaml_dir>/patches/`（与 `linglong.yaml` 同级）
```

### 步骤 4：`SKILL.md` 更新文档

**目标文件**：`skills/src2linyaps.debian.analyze-rules/SKILL.md`
**修改位置**：输出段（第 59 行起）与约束段（第 94 行起）。

**输出段**新增 `migrate-patches.py` 输出字段说明：
- `has_patches`：是否存在补丁
- `patches_applied`：成功应用的补丁列表
- `patches_failed`：失败补丁列表（含 `name`/`error`/`rej_content`）
- `patches_disabled`：被注释禁用的补丁列表
- `patch_commands`：前置注入 `build_section` 的 shell 命令字符串
- `patches_dir`：补丁文件输出目录

**约束段**新增（第 102 行后）：
- 补丁迁移为非阻断：失败记警告，不阻断 Path A
- 补丁文件复制到 `patches/`（与 `linglong.yaml` 同级），映射到容器 `/project/linglong/patches/`
- `patch_commands` 前置于 `build_section` 的构建命令之前
- 补丁以 shell 命令（`patch -p1`）形式注入 `build:` 段，非新增 schema 字段
- 使用显式逐文件 `patch -p1` 命令（非 glob），保留 series 顺序
- `scan-patches.py` 与 `migrate-patches.py` 为独立新脚本，不修改 `analyze-rules.py`

## 关键文件与锚点

| 文件 | 符号/区域 | 原因 |
|------|-----------|------|
| `skills/src2linyaps.debian.analyze-rules/scripts/scan-patches.py` | 全文件（新建） | 补丁扫描脚本，独立于 `analyze-rules.py` |
| `skills/src2linyaps.debian.analyze-rules/scripts/migrate-patches.py` | 全文件（新建） | 补丁迁移核心脚本，subprocess 调 `scan-patches.py` |
| `for-multica/agent.md` | A3 段 L48 → A4 段 L49 之间 | 插入 A3.3 步骤 |
| `skills/src2linyaps.debian.analyze-rules/SKILL.md` | 输出段 L59、约束段 L94 | 文档补丁字段与约束 |
| `skills/src2linyaps.debian.build-res-generate/scripts/generate-linglong-yaml.py` | `build_yaml()` `PATCH_BUILD_DEPS` 追加 | 检测 `build_section` 含 `patch -p1` 时追加 `patch` 到 `build_depends` |
| `skills/src2linyaps.debian.build-res-generate/SKILL.md` | 约束段 | 文档补丁构建依赖自动追加 |
| `skills/config/linglong-schema.yaml` | `top_level.allowed` L19-30 | 确认无 `patches` 键（只读参考，不修改） |

## 补丁命令注入示例

`migrate-patches.py` 输出的 `patch_commands` 前置到 A3.2 的 `build_section`，再传入 `generate-linglong-yaml.py --build-section`：

```sh
# 注入后 build_section（patch_commands 在前）：
export SRC_ROOT=$(ls -d /project/linglong/sources/deepin-calculator/*)
cd ${SRC_ROOT}
patch -p1 < /project/linglong/patches/0001-fix-foo.patch
patch -p1 < /project/linglong/patches/0002-fix-bar.patch

cmake -B build-linglong \
    -DCMAKE_INSTALL_PREFIX=${PREFIX} \
    -DCMAKE_BUILD_TYPE=Release
cmake --build build-linglong -j$(nproc)
cmake --install build-linglong
```

`generate-linglong-yaml.py` 的 `replace_hardcoded_prefixes()`（L121）和 `normalize_install_dirs()`（L139）对 `patch -p1` 命令无影响——不含 `/usr` 或前缀模式。`validate-linglong-yaml.py` 的 forbidden patterns 不含 `patch`——不触发校验错误。

## Quilt 合并工作目录结构

```
build_tmp_dir/
└── <package_id>-patch-merge/
    ├── <上游源码文件>              # 从 project_path 复制
    ├── CMakeLists.txt              # （或 meson.build, Makefile 等）
    └── debian/                     # 从 debian_path 复制
        ├── rules
        ├── changelog
        ├── control
        ├── source/
        │   └── format              # "3.0 (quilt)"
        └── patches/
            ├── series
            ├── 0001-fix-foo.patch
            └── 0002-fix-bar.patch
```

## 失败处理策略

| 场景 | 动作 |
|------|------|
| 无 `debian/patches/series` | 跳过 A3.3，输出无补丁 |
| series 存在但为空 | 跳过 A3.3，输出无补丁 |
| `source/format` 为 `3.0 (native)` | `has_patches=False`，跳过 A3.3 |
| 全部补丁应用成功 | 复制全部补丁文件 + 注入命令 |
| 部分补丁失败（过期） | LLM 读 reject 内容，按最新源码修改补丁，重跑 `--retry` |
| LLM 修复后仍失败 | 跳过该补丁，记 `patch_skipped` 警告，继续迁移其余补丁 |
| 禁用补丁（series 中 `#` 注释） | 静默跳过，不复制不应用 |

非阻断：补丁失败不阻断 Path A。agent 记录警告，继续 A4（build-res-generate），仅用成功的补丁。

## LLM 补丁修复流程

`quilt push` 对某补丁失败时：
1. `migrate-patches.py` 捕获：补丁名、`quilt push` stderr（显示哪个 hunk 失败）、`.rej` 文件内容（被拒绝的 hunk）。
2. LLM 接收：失败补丁文件内容、reject 文件内容、当前源文件内容（被补丁的文件）。
3. LLM 修改补丁文件以匹配当前源码：调整行号、更新上下文行、按需拆分/合并 hunk。
4. 重跑 `migrate-patches.py --retry`：仅重试之前失败的补丁；仍失败 → 跳过，记警告。

## 边界情况

1. **补丁文件在子目录**（series 引用 `debian/foo/0001.patch`）：`scan_patches()` 保留相对路径；`copy_patches()` 保留目录结构（`os.makedirs` 父目录）。
2. **多个源码仓库**（如 calculator 示例有 2 个 git 源）：`source_name` 参数决定 `cd` 到哪个源码目录；补丁仅应用到指定源码。
3. **`patch -p1` vs `patch -p0`**：Debian quilt 补丁统一为 `p1`，硬编码 `patch -p1`。
4. **`scan-patches.py` 与 `migrate-patches.py` 均为独立新文件**：不修改 `analyze-rules.py`，不 import 它；`migrate-patches.py` 通过 subprocess 调用 `scan-patches.py`。

## 验证

1. **`scan-patches.py` 单元测试**：创建 mock `debian/patches/series`（含激活+禁用补丁），验证解析结果。前提：在临时目录构造 `debian/patches/series` + `debian/source/format`。
2. **`migrate-patches.py` 集成测试**：用含补丁的真实 Debian 源码包（`apt-get source <pkg>` 取一个 `3.0 (quilt)` 格式包），验证 quilt 应用 + 补丁文件复制 + 命令生成。命令：
   ```bash
   cd /tmp && apt-get source -d --print-source-path some-quilt-package 2>/dev/null
   dpkg-source -x *.dsc /tmp/test-pkg-src
   python3 migrate-patches.py --project-path /tmp/test-pkg-src --debian-path /tmp/test-pkg-src/debian --build-tmp-dir /tmp/test-buildtmp --source-name test-pkg --package-id test-pkg --target-yaml /tmp/test-output/CI_ll_test-pkg/linglong.yaml
   ```
   预期：stdout YAML 含 `patches_applied` 非空、`patches_dir` 下有 `.patch` 文件、`patch_commands` 含 `cd` + `patch -p1` 行。
3. **端到端**：对一个含补丁的包跑完整 Path A，验证 `linglong.yaml` 的 `build:` 段含补丁命令、`patches/` 目录（与 `linglong.yaml` 同级）存在补丁文件。
4. **校验**：对生成的 YAML 跑 `python3 validate-linglong-yaml.py --build-tool <tool_type> --schema skills/config/linglong-schema.yaml`，退出码 0（补丁命令不触发校验错误）。

## 假设与应急

- **假设**：linglong 构建容器中 `/project/linglong/patches/` 路径可写。`patch -p1` 在容器内执行，`patch` 包未必预装——由 `generate-linglong-yaml.py` 检测 `build_section` 含 `patch -p1` 时自动追加到 `buildext.apt.build_depends`（参照 clang 追加模式）。若实际容器路径不同（如 `/project/patches/`），`generate_patch_commands()` 中的路径前缀需相应调整——该路径为 `migrate-patches.py` 中可配置常量 `LINGLONG_PATCHES_DIR = '/project/linglong/patches'`。
- **宿主系统依赖**：`migrate-patches.py` 用 `quilt push -a` 验证补丁应用，宿主需预装 `quilt`（`which quilt` 可用）。`patch` 命令在容器内执行（非宿主），但宿主亦需 `patch`（`quilt` 内部调用）。
- **假设**：`quilt push -a` 在合并工作目录中可正常工作（需 `QUILT_PATCHES` 环境变量）。已通过 `QUILT_PATCHES=debian/patches` 环境变量设置，不依赖 `.quiltrc`。
- **应急**：若 `quilt` 不可用（`which quilt` 失败），`migrate-patches.py` 输出 `{has_patches: false, error: 'quilt not found'}`，A3.3 降级为跳过——不阻断 Path A。

## 需创建/修改的文件

| 文件 | 操作 | 说明 |
|------|------|------|
| `skills/src2linyaps.debian.analyze-rules/scripts/scan-patches.py` | 新建 | 补丁扫描脚本（独立，不修改 analyze-rules.py） |
| `skills/src2linyaps.debian.analyze-rules/scripts/migrate-patches.py` | 新建 | 补丁迁移脚本（subprocess 调 scan-patches.py） |
| `skills/src2linyaps.debian.analyze-rules/SKILL.md` | 修改 | 文档补丁扫描+迁移步骤 |
| `for-multica/agent.md` | 修改 | Path A 新增 A3.3 步骤 |
| `docs/20261020-patch-migration-plan.md` | 新建 | 导出实施方案全文到 docs 目录归档 |

**不修改 `analyze-rules.py`**——补丁相关全部为新功能，在新代码文件中独立实现。
**修改 `generate-linglong-yaml.py`**——检测 `build_section` 含 `patch -p1` 时，将 `patch` 追加到 `buildext.apt.build_depends`（参照 clang 的 `CLANG_BUILD_DEPS` 追加模式 L268-270），因为 `patch -p1` 在容器内执行、`patch` 包未必预装。
**无需修改**：`linglong-schema.yaml`、`validate-linglong-yaml.py`、`linglong-defaults.json`、`build-tool-patterns.yaml`、`common-building-rules.yaml`——补丁以 `build:` 段 shell 命令形式集成，非新增 schema 字段。

### 步骤 5：导出实施方案到 `docs/` 目录

**目标文件**：`docs/20261020-patch-migration-plan.md`（新建）

将本方案文件（`local://patch-migration-plan.md` 的完整内容）复制到仓库根级 `docs/` 目录，文件名遵循现有 docs 命名风格 `YYYYMMDD-<slug>-plan.md`（参照 `docs/src2linyaps-debug-build-run-verify-plan.md`、`docs/agents-skills-perf-slim-plan.md`）。

内容为本方案全文（含背景、步骤 1–4、验证、假设与应急、文件清单、步骤 5 本身），供仓库归档与团队查阅。此步骤不改变 skill 代码或工作流逻辑，仅增加文档输出。
