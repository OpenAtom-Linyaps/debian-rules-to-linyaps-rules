---
name: src2linyaps.debug
description: >
  【debian-rules-to-linyaps / debug 节点】调试纠正 SKILL。
  独立调试入口（user-invocable）：用户注入已有玲珑构建工程打包出的 layer + 问题描述，
  本 skill 解压 layer、对照分析，诊断 build 规则错误、common res 缺失等问题；
  修复通过调用本仓库 `skills/` 下具体内部 skills 完成（本体纯分析，不改文件）；
  修复校验通过后默认调用 `linyaps-src-init-dispatch` 的 `assign_packer` 指派
  linyaps-packer 重新打包（用户可指定不指派，直接结束）。
  不调用仓库外 skills（如 resource-collector / deb-analysis / linglong-fix / compat-testing）。
argument-hint: '<layer_path> <problem_desc> [--src-path=<path>] [--src-url=<url>]'
user-invocable: true
---

# src2linyaps.debug — 调试纠正 SKILL

分析纠正已有玲珑（Linyaps）构建工程。用户通过提示词注入已有构建工程打包出的 layer + 问题描述，本 skill 解压 layer 进行诊断，修复通过调用内部 skills 完成，完成后默认指派 `linyaps-packer` 重新打包。

## 设计核心

- **纯分析**：本 skill 本体只做「解压 layer → 对照分析 → 问题诊断」，不做修复实现。
- **修复调用具体 skills**：修复动作通过 `skill()` 调用 `skills/` 下的内部 skills 完成；common res 补齐由本 skill 直接落盘（无专属内部 skill）。
- **修复后指派 packer**：复用 `linyaps-src-init-dispatch` 的 `assign_packer` action（默认）；用户指定「不指派」时直接结束。

## 目录约定

- 本 skill 无独立 scripts 目录；构建/运行验证由 LLM 直接执行 `ll-builder` 命令。
- upstream 源文件获取：通过 `skill()` 调用 `linyaps-upstream-query` skill 查询；用户指定的 `src_path`/`src_url` 优先，upstream 查询仅补缺。
- 构建工具选择：LLM 检测 `pak_linyaps.sh` 存在性选择 pak_linyaps 或 ll-builder；pak_linyaps 参数由 LLM 读取脚本自行确定。
- 内部资源（只读复用，路径相对于 workspace 根目录）：
  - `skills/src2linyaps.debian.build-res-generate/scripts/generate-linglong-yaml.py`
  - `skills/src2linyaps.debian.build-res-generate/scripts/validate-linglong-yaml.py`
  - `skills/src2linyaps.debian.build-res-generate/reference/common-building-rules.yaml|.md`
  - `skills/src2linyaps.debian.analyze-rules/scripts/analyze-rules.py`
  - `skills/config/linglong-schema.yaml`
  - `skills/config/linglong-defaults.json`

## 输入

| 名称 | 类型 | 必填 | 描述 |
|------|------|------|------|
| `layer_path` | string | 是 | 已有构建工程打包出的 layer 文件 |
| `problem_desc` | string | 是 | 问题描述（构建失败/运行异常/common res 缺失等） |
| `project_path` | string | 否 | 被纠正的工程目录（含 `linglong.yaml`） |
| `src_path` | string | 否 | 用户指定的源码路径（本地路径或归档文件）；未提供时通过 upstream 查询获取 |
| `src_url` | string | 否 | 用户指定的源码下载 URL；未提供时通过 upstream 查询获取 |
| `agent_config_path` | string | 否 | 指派 packer 时指向的 `agent-config.json` |

## 内部 skills 清单与用途

以下为修复 workflow 中可调用的内部 skills（均位于 `skills/` 下）：

| Skill | 路径 | 用途（debug 修复时可调用场景） |
|-------|------|------------------------------|
| `src2linyaps.debian.test-deps` | `skills/src2linyaps.debian.test-deps/` | 校验 `Build-Depends` 可用性（修复 buildext.build_depends 前探测） |
| `src2linyaps.debian.analyze-control` | `skills/src2linyaps.debian.analyze-control/` | 解析 debian/control，合并 buildDepends/runtimeDepends（修复 `buildext` 依赖段） |
| `src2linyaps.debian.analyze-rules` | `skills/src2linyaps.debian.analyze-rules/` | 分析 debian/rules → build_section、build_tool、resources（修复 build 规则错误，比对产物） |
| `src2linyaps.debian.build-res-generate` | `skills/src2linyaps.debian.build-res-generate/` | 生成/重新生成 `linglong.yaml` + 校验；运行库丢失（非 apt 可补齐）时 agent 按其 SKILL.md 用 `--custom-deb-urls` 注入 deb 提取（`generate-linglong-yaml.py` / `validate-linglong-yaml.py` / `download_custom_debs.sh`） |
| `src2linyaps.source.detect-tool` | `skills/src2linyaps.source.detect-tool/` | 检测构建工具类型（cmake/meson/make/autotools），修复 build 段工具错误 |
| `src2linyaps.source.analyze-args` | `skills/src2linyaps.source.analyze-args/` | 提取编译参数与默认值（修复 configure/cmake 参数） |
| `linyaps-git-workflow` | `skills/linyaps-git-workflow/` | Git 提交/推送修复后的工程（阶段四条件推送） |
| `linyaps-upstream-query` | `for-multica/skills/linyaps-upstream-query/` | 包名查询上游源码下载地址（用户未提供 src_path/src_url 时调用） |

> **授权说明**：`linyaps-src-init-dispatch` 原约束「仅 debian-rules-to-linyaps agent 调用」。本 skill 属同一 workflow 体系的 debug 环节，特此在本文档显式授权其 `assign_packer` 调用场景，其他 action（`update_issue_status` / `check_agent_status`）不在本 skill 授权范围内。

## 工作流程（五阶段）

开始前先确认 workspace 根目录（含 `skills/` 与 `agents/`），记作 `WORKSPACE_ROOT`，所有脚本调用使用相对 `WORKSPACE_ROOT` 的路径，**不要** `cd` 后执行。

### 阶段一 · 解压 layer

```bash
ll-builder extract <layer_path> <workdir>
```

- 参考：`skills/src2linyaps.debug/ll-builder.command.reference.md`
- 解压后定位 `<workdir>/files`，即 `linglong.yaml` 声明的 `$PREFIX` 内容。

### 阶段二 · 对照分析（纯分析，不改文件）

1. 读工程 `linglong.yaml`（package.id/name/version、command、build、buildext、modules）
2. 对照 `<workdir>/files/` 结构（bin/lib/share）+ `problem_desc`，判定问题类型：
   - **build 规则错误**：工具类型 / DESTDIR / 硬编码 `/usr` / 编译参数缺失
   - **command 指向的可执行文件缺失**
   - **common res 缺失**：`share/applications/*.desktop`、`share/icons/hicolor/**`、`share/metainfo|appdata`、`share/locale`
   - **buildext 依赖缺失/多余**
   - **运行库丢失（非 apt 可补齐）**：`<workdir>/files/lib` 下 `.so` 文件 `ldd` 检测有 `not found`，且缺失库不在 apt 仓库（`apt-cache show <libname>` 无结果）→ 需通知 agent 调用 `build-res-generate` 通过自定义 deb URL 下载补齐
   - **yaml 格式 / base / runtime 错误**
3. `debian_path` 存在时，用 `analyze-rules.py` 辅助比对 debian 产物与 `<workdir>/files/`
4. 输出结构化诊断清单（含问题类型 + 定位 + 依据）

### 阶段三 · 修复（调用具体内部 skills）

| 诊断问题 | 调用的内部 skill | 核心动作 |
|---------|-----------------|---------|
| build 工具类型错误 | `src2linyaps.source.detect-tool` | 检测正确工具类型 |
| build 参数/configure 错误 | `src2linyaps.source.analyze-args` + `src2linyaps.debian.analyze-rules` | 提取/重生成 build 段 |
| 重新生成 linglong.yaml | `src2linyaps.debian.build-res-generate` | `generate-linglong-yaml.py` |
| buildext 依赖问题 | `src2linyaps.debian.analyze-control` + `src2linyaps.debian.test-deps` | 修正 buildDepends/runtimeDepends |
| 运行库丢失（非 apt 可补齐） | `src2linyaps.debian.build-res-generate` | 通知 agent 调用本技能，按其 SKILL.md 使用 `--custom-deb-urls` 重新生成 `linglong.yaml`，注入 deb 提取命令补齐缺失运行库 |
| common res 补齐 | 直接编辑 `files_res/` + `$PREFIX` 对应路径（遵循规范） | 本 skill 落盘 |
| 修复后二次校验 | `src2linyaps.debian.build-res-generate` | `validate-linglong-yaml.py`（见下） |

**重新生成 linglong.yaml**：
```bash
python3 skills/src2linyaps.debian.build-res-generate/scripts/generate-linglong-yaml.py \
  --control-info <control_info.yaml> \
  --build-section "<build_section>" \
  --build-tool <tool_type> \
  --build-args '<build_args_json>' \
  --extra-args '<extra_args_string>' \
  --package-version <baseline> \
  --defaults skills/config/linglong-defaults.json \
  --reference skills/src2linyaps.debian.build-res-generate/reference/common-building-rules.yaml \
  --output <project_path>/linglong.yaml
```

**修复后二次校验**：
```bash
python3 skills/src2linyaps.debian.build-res-generate/scripts/validate-linglong-yaml.py \
  <project_path>/linglong.yaml \
  --schema skills/config/linglong-schema.yaml \
  --build-tool <tool_type> \
  --reference skills/src2linyaps.debian.build-res-generate/reference/common-building-rules.yaml
```
- 退出码 0 → 校验通过，继续阶段四（构建验证 + 运行验证 + 条件 Git 推送）
- 退出码非 0 → 输出错误列表，按错误修复后重新校验，直至通过或判定无法修复

### 阶段四 · 构建验证 + 运行验证 + 条件 Git 推送

`validate-linglong-yaml.py` 校验通过后，先构建验证 + 运行验证，再根据结果决定 Git 推送方式。

#### 4.1 构建验证

`validate-linglong-yaml.py` 校验通过后，先获取源文件、选择构建工具，再执行构建。重试 ≤ 2 次（含首次），单次超时窗口 1800 秒。

##### 4.1.0 获取源文件

获取源文件的优先级：**用户指定 > upstream 查询**。

- 用户指定 `src_path`（本地路径）→ 直接使用，不调 upstream。
- 用户指定 `src_url`（下载 URL）→ 直接使用，不调 upstream。
- 两者均无 → 通过 `skill()` 调用 `linyaps-upstream-query` skill 查询补缺。

`pkgName` 从 `<project_path>/linglong.yaml` 的 `package` 字段获取（`linyaps-upstream-query` 查询所需）。若 linglong.yaml 无 `package` 字段，跳过 upstream 查询。

`linyaps-upstream-query` skill 内部完成查询、下载、解压，返回 `src_path`/`src_url`/`arch`/`orig_version` 等字段。调用方只需从返回 JSON 的 `tasks[]` 中提取字段，`errors[]` 中的失败不阻塞构建。

##### 4.1.1 构建工具选择
根据项目目录检测构建工具类型：

```bash
# 检测项目类型：项目目录有 pak_linyaps.sh → binary 类型；否则 → source 类型
if [[ -f "<project_path>/pak_linyaps.sh" ]]; then
  build_tool="pak_linyaps"   # binary 类型
else
  build_tool="ll-builder"    # source 类型
fi
```

##### 4.1.2 构建执行

记录开始时间，用于后续 `.layer` 文件检测：

```bash
start_time=$(date +%s)
```

**binary 分支（`build_tool == "pak_linyaps"`）**：

LLM **必须先读取项目目录下的 `pak_linyaps.sh` 脚本**，理解其支持的参数和用法，再根据当前上下文（arch、orig_version、src_path、output_dir）构造正确的调用命令。不得跳过读取直接硬编码参数。`output_dir` 默认可用 `<project_path>/output`，由 LLM 读取脚本后确定。

参考调用模式（来自 `linglong-binary-runner/scripts/run_tasks.sh` L191-195）：

```bash
cd <project_path>
# LLM 先读取 pak_linyaps.sh 理解其参数，再构造命令
./pak_linyaps.sh --linyaps_arch=<arch> --origin_version=<orig_version> \
  --src_path=<src_path> --output_dir=<output_dir> [--build_tmp_dir=<tmp>]
```

- 重试 ≤ 2 次（含首次），单次超时 1800 秒，退出码 124 消歧逻辑同 source 分支。
- 构建成功标志：`output_dir` 下生成 `*_binary.layer` 文件。

```bash
# 构建尝试（最多 2 次）
for attempt in 1 2; do
  echo "== 构建尝试 $attempt/2 (pak_linyaps) =="
  timeout 1800 <pak_linyaps_command>  # LLM 读取脚本后构造的实际命令
  build_rc=$?

  # 退出码 124 = timeout 命令超时，需消歧
  if [[ $build_rc -eq 124 ]]; then
    if pgrep -x ll-builder >/dev/null 2>&1 || pgrep -x fuse-overlayfs >/dev/null 2>&1 || pgrep -x erofsfuse >/dev/null 2>&1; then
      echo "== 构建仍在进行，继续等待 =="
      wait
      build_rc=$?
    else
      echo "== 构建进程已退出（超时无活跃进程），判定挂起 =="
    fi
  fi

  if [[ $build_rc -eq 0 ]]; then
    echo "== 构建成功 =="
    break
  fi

  [[ $attempt -lt 2 ]] && sleep 10 && echo "== 重试构建 =="
done

if [[ $build_rc -eq 0 ]]; then
  # 检测 output_dir 下 *_binary.layer 文件
  layer_file=$(find <output_dir> -maxdepth 1 -name "*_binary.layer" -type f -newermt "@$start_time" 2>/dev/null | head -1)
  if [[ -n "$layer_file" ]]; then
    build_verify="passed"
  else
    build_verify="failed"
  fi
else
  build_verify="failed"
fi
```

**source 分支（`build_tool == "ll-builder"`）**：

执行 `ll-builder build --skip-output-check` + `ll-builder export --layer --no-develop -z zstd`。

```bash
# 构建尝试（最多 2 次）
for attempt in 1 2; do
  echo "== 构建尝试 $attempt/2 =="
  timeout 1800 ll-builder build --skip-output-check --build-dir <project_path>
  build_rc=$?

  # 退出码 124 = timeout 命令超时，需消歧
  if [[ $build_rc -eq 124 ]]; then
    if pgrep -x ll-builder >/dev/null 2>&1 || pgrep -x fuse-overlayfs >/dev/null 2>&1 || pgrep -x erofsfuse >/dev/null 2>&1; then
      echo "== 构建仍在进行，继续等待 =="
      wait
      build_rc=$?
    else
      echo "== 构建进程已退出（超时无活跃进程），判定挂起 =="
    fi
  fi

  if [[ $build_rc -eq 0 ]]; then
    echo "== 构建成功 =="
    break
  fi

  [[ $attempt -lt 2 ]] && sleep 10 && echo "== 重试构建 =="
done

# 构建失败则跳过导出，标记构建验证失败
if [[ $build_rc -ne 0 ]]; then
  build_verify="failed"
else
  # 导出 layer
  timeout 1800 ll-builder export --layer --no-develop -z zstd --build-dir <project_path>
  export_rc=$?

  # 退出码 124 消歧（同上）
  if [[ $export_rc -eq 124 ]]; then
    if pgrep -x ll-builder >/dev/null 2>&1 || pgrep -x fuse-overlayfs >/dev/null 2>&1 || pgrep -x erofsfuse >/dev/null 2>&1; then
      wait
      export_rc=$?
    fi
  fi

  if [[ $export_rc -eq 0 ]]; then
    # 检测本轮导出的 .layer 文件
    layer_file=$(find <project_path> -maxdepth 1 -name "*.layer" -type f -newermt "@$start_time" 2>/dev/null | head -1)
    if [[ -n "$layer_file" ]]; then
      build_verify="passed"
    else
      build_verify="failed"
    fi
  else
    build_verify="failed"
  fi
fi
```

**约束**：
- 源文件获取优先级：用户指定 `src_path`/`src_url` > `skill()` 调用 `linyaps-upstream-query` 查询；查询失败时跳过源文件获取，不阻塞构建。
- 构建工具选择依据：`pak_linyaps.sh` 存在 → binary（pak_linyaps）；否则 → source（ll-builder）。
- binary 分支：LLM 必须先读取 `pak_linyaps.sh` 脚本理解参数，再构造调用命令；不得跳过读取直接硬编码参数。
- binary 分支构建成功标志：`output_dir` 下 `*_binary.layer` 文件。
- `--skip-output-check`：跳过输出检查（调试阶段允许非标准输出）。
- `--layer --no-develop -z zstd`：导出 layer 格式，不包含 develop 层，zstd 压缩。
- 退出码 124 时**不得仅凭超时判失败**：必须检查 `ll-builder` / `fuse-overlayfs` / `erofsfuse` 进程是否仍活跃。
- `.layer` 文件检测：仅取本轮构建开始后生成的（`-newermt "@$start_time"`）。

#### 4.2 运行验证

根据 `build_tool` 选择运行验证方式。构建验证失败时跳过（`run_verify="skipped"`）。

**binary 分支（`build_tool == "pak_linyaps"`）**：

LLM 读取 `linglong.yaml` 的 `command` 字段构造运行命令，从 `pak_linyaps` 的 `output_dir` 运行 layer。

```bash
if [[ "$build_verify" == "passed" ]]; then
  # LLM 从 linglong.yaml 读取 command 字段，构造运行命令
  # 从 pak_linyaps 的 output_dir 运行 *_binary.layer
  timeout 30 <run_command>
  run_rc=$?

  # 退出码 0 = 正常退出（通过）；124 = timeout 触发但进程可能仍在运行（视为通过）
  if [[ $run_rc -eq 0 || $run_rc -eq 124 ]]; then
    run_verify="passed"
  else
    run_verify="failed"
  fi
else
  run_verify="skipped"
fi
```

**source 分支（`build_tool == "ll-builder"`）**：

使用 `ll-builder run` 验证应用可正常启动。

```bash
if [[ "$build_verify" == "passed" ]]; then
  # 使用 ll-builder run 验证应用可正常启动
  timeout 30 ll-builder run --build-dir <project_path>
  run_rc=$?

  # 退出码 0 = 正常退出（通过）；124 = timeout 触发但进程可能仍在运行（视为通过）
  if [[ $run_rc -eq 0 || $run_rc -eq 124 ]]; then
    run_verify="passed"
  else
    run_verify="failed"
  fi
else
  run_verify="skipped"  # 构建失败时跳过运行验证
fi
```

**约束**：
- binary 分支：LLM 读取 `linglong.yaml` 的 `command` 字段构造运行命令，从 `output_dir` 运行 layer。
- source 分支：使用 `ll-builder run --build-dir <project_path>`。
- 超时 30 秒（应用启动验证，非完整功能测试）。
- 退出码 0 或 124 = 通过；其他非零退出码 = 失败。
- 构建验证失败时跳过运行验证（`run_verify="skipped"`）。
- 运行验证失败且错误含 `error while loading shared libraries` / `cannot open shared object file` → 回退阶段二，按「运行库丢失（非 apt 可补齐）」重新诊断，阶段三路由到 `build-res-generate`（`--custom-deb-urls`）修复后重新构建验证

#### 4.3 条件 Git 推送

根据构建验证 + 运行验证结果决定推送方式。

**成功（`build_verify="passed"` 且 `run_verify="passed"`）**：
```bash
bash skills/linyaps-git-workflow/scripts/git-workflow.sh commit_and_push \
  --init_repo_dir=<repo_dir> [--data-dir=<data_dir>]
```
- 正常推送，`commit_and_push` 自动处理缓存清理、upstream 同步、pre-commit 守卫、动态 commit message 生成、commit、push。

**失败（`build_verify="failed"` 或 `run_verify="failed"`）**：
```bash
# 1. 先正常推送修复
push_output=$(bash skills/linyaps-git-workflow/scripts/git-workflow.sh commit_and_push \
  --init_repo_dir=<repo_dir> [--data-dir=<data_dir>])

# 2. 从 commit_and_push 输出 JSON 中解析 commit_sha
commit_sha=$(echo "$push_output" | jq -r '.commit_sha // empty')

# 3. 通过 multica comment 追加警告评论（任务 ID 来自环境变量 MULTICA_ISSUE_TASK_ID）
multica issue comment add "$MULTICA_ISSUE_TASK_ID" \
  --content "⚠️ build/run verification failed: build=$build_verify run=$run_verify (commit: $commit_sha)"
```

- 用 `multica issue comment add` 追加警告评论（项目已有机制，issue 页面直接可见）。
- 任务 ID 来自环境变量 `MULTICA_ISSUE_TASK_ID`，与 `linyaps-src-init-dispatch` 的 `assign_packer`/`update_issue_status` 使用同一模式。

### 阶段五 · 指派 packer（默认）

- **默认**：修复 + 校验通过后，调用 `linyaps-src-init-dispatch` 的 `assign_packer`：

```json
{
  "action": "assign_packer",
  "pkgName": "<package_id>",
  "project_dir": "CI_ll_<package_id>",
  "arch": "x86_64",
  "workflow_type": "debian-rules-to-linyaps",
  "data_dir": "<data_dir>",
  "workspace": "linyaps",
  "agent_config_path": "<agent_config_path>"
}
```

- **可选**：若用户指定「不指派」，则修复校验通过后直接结束任务，输出修复报告。

## 约束

1. **`files/` 即 `$PREFIX`**：解压出的 `<workdir>/files` 目录就是 `linglong.yaml` 声明的安装前缀。
2. **禁止硬编码 `/usr`**：遵循 `src2linyaps.constraints` **SKILL**（${PREFIX} 安装目录、DESTDIR 黑名单）；`build:` 段所有安装目录参数使用 `${PREFIX}`，校验阶段自动检测。
3. **修复后必须校验**：任何改动必须通过 `validate-linglong-yaml.py` 校验，禁止跳过。
4. **清理临时目录**：临时解压目录处理完清理。
5. **仅调用仓库内 skills**：修复仅能调用 `skills/` 下内部 skills，禁止调用外部 skills（resource-collector / deb-analysis / linglong-fix / compat-testing 等，这些独立于本仓库 `skills/`）。
6. **`assign_packer` 需 `agent_config_path`**：用户未提供时，如需要指派则向用户确认 `agent_config_path`。
7. **构建验证重试限制**：`ll-builder build` + `ll-builder export` 各最多 2 次尝试（含首次），超时 1800 秒/次。退出码 124 时必须检查 `ll-builder`/`fuse-overlayfs`/`erofsfuse` 进程活跃性，不得仅凭超时判失败。
8. **运行验证超时**：`ll-builder run` 超时 30 秒；退出码 0/124 = 通过，其他非零 = 失败。
9. **Git 推送条件性**：构建+运行验证通过 → 正常推送；验证失败 → 仍推送但通过 `multica issue comment add` 追加警告评论（任务 ID 来自 `MULTICA_ISSUE_TASK_ID`）。

## 输出

修复报告：
- 诊断问题（问题类型 + 定位 + 依据）
- 调用的 skill
- 改动 before/after
- 补齐 common res 清单
- 校验结果
- 构建验证结果（passed/failed + .layer 文件路径）
- 运行验证结果（passed/failed/skipped + 退出码）
- Git 推送结果（committed + commit_sha + 是否追加 multica 警告评论）
- 指派结果 / 结束标记
