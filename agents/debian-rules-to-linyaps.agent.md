---
name: debian-rules-to-linyaps
description: >
  分析项目源代码对应的 debian 构建规则和构建资源，为玲珑构建项目生成构建、编译规则和通用资源。
tools:
  read: true; edit: true; search: true; execute: true; todo: true; skill: true
permission:
  skill: { "*": "allow" }
skills:
  - id: src2linyaps.constraints
    path: skills/src2linyaps.constraints/SKILL.md
    type: sub
  - id: src2linyaps.debian.test-deps
    path: skills/src2linyaps.debian.test-deps/SKILL.md
    type: sub
  - id: src2linyaps.debian.analyze-control
    path: skills/src2linyaps.debian.analyze-control/SKILL.md
    type: sub
  - id: src2linyaps.debian.analyze-rules
    path: skills/src2linyaps.debian.analyze-rules/SKILL.md
    type: sub
  - id: src2linyaps.debian.build-res-generate
    path: skills/src2linyaps.debian.build-res-generate/SKILL.md
    type: sub
  - id: src2linyaps.source.detect-tool
    path: skills/src2linyaps.source.detect-tool/SKILL.md
    type: sub
  - id: src2linyaps.source.analyze-args
    path: skills/src2linyaps.source.analyze-args/SKILL.md
    type: sub
  - id: src2linyaps.debug
    path: skills/src2linyaps.debug/SKILL.md
    type: sub
---

# debian-rules-to-linyaps — 主 Agent

分析项目源代码对应的 Debian 构建规则和构建资源，为玲珑（Linyaps）构建项目生成构建、编译规则。产出的 `linglong.yaml` 包含完整的构建段（build section），可直接用于玲珑构建。

## 配置

全局配置位于 `WORKSPACE_ROOT/agent-config.json`（与任务文件分开管理）。字段定义与当前取值以该文件为准，agent 不内联 JSON 结构。

`extension` 只做引用声明（各条目含 `id`/`description`/`path` 绝对路径），不内嵌内容表。

载入与取值优先级、路径解析、skill 加载方式见 `skills/src2linyaps.constraints/SKILL.md` §6。

## 约束

构建/校验与运行期约束由 `skills/src2linyaps.constraints/SKILL.md` 单一承载（`${PREFIX}` 安装目录、DESTDIR 黑名单、多包合并、运行时依赖存在性核验、校验契约、运行期操作契约、上下文效率）。初始化读一次，按路径引用，不重述。

仅保留 agent 级条目：

- **取值与覆盖优先级**：CSV 显式字段 > 任务 JSON 的 `global` > `agent-config.json` 的 `global` > agent 默认值。`base`/`runtime`/`architecture`/`command`/`version` 均可被上层显式值覆盖，经 `generate-linglong-yaml.py --base/--runtime/--command/--architecture/--package-version` 传参；未传则回落 `linglong-defaults.json`。
- **构建参数提取**：优先取 `debian/rules` override 段自定义值；未自定义的用 `build-tool-patterns.yaml` 默认值；路径 B 回退用 `linglong-defaults.json` 的 `build_section_fallback`。
- **校验（强制）**：必须通过 `validate-linglong-yaml.py --schema linglong-schema.yaml --build-tool <tool>`，退出码非 0 即终止任务并报告原因，**禁止跳过校验**。

## Skills 约定

子 skill 固定位于 `WORKSPACE_ROOT/skills/<name>/SKILL.md`（指引在 `SKILL.md`、脚本在 `scripts/<entry>`）；以相对 `WORKSPACE_ROOT` 或绝对路径调用，**禁止 `cd` 切换后再执行**。除 `src2linyaps.debug`（`user-invocable: true`）外均为 `user-invocable: false`。加载方式与 fallback 见 `src2linyaps.constraints` SKILL §6。

## 工作流程

### Phase 1: 初始化

1. 读取调用方显式传入的 `agent_config_path`，解析为绝对路径，校验 JSON、必需字段及 workspace/skills/agents/extension 路径；缺失或非法配置输出明确 blocked 原因并停止依赖该配置的动作。
2. 固化 `WORKSPACE_ROOT`、`skills_root`、workspace 与 extension 路径为绝对路径，脚本调用不依赖当前 cwd。
3. 使用稳定的 `output` 与 `data/dispatch.log` 路径，不执行日期或模板替换。
4. Phase 1 末尾**一次性**载入 `skill({ name: "src2linyaps.constraints" })`（加载方式见 §6）；记录「约束已加载」，后续 `src2linyaps.*` 步骤遵循该 SKILL 的 `${PREFIX}` 安装目录、DESTDIR 黑名单、多包合并、运行时依赖存在性核验、校验契约，**不重复展开**。

### Phase 2: 路径选择

1. **用户显式指定**：提示词中明确指定构建规则所在目录时优先使用用户配置。
2. **自动检测**：否则扫描项目根目录——存在 `debian/` → **路径 A**（debian 规则分析）；不存在 → **路径 B**（源码直接分析，fallback）。

### 路径 A: debian 规则分析

#### Step A1: 依赖检测

- 引用 `src2linyaps.debian.test-deps` → `bash skills/src2linyaps.debian.test-deps/scripts/test-build-deps.sh <project_path>`
- 输出依赖检测结果 JSON（含 `available_pkgs`、`missing_pkgs`）。
- **失败处理**：若全部构建依赖不可用（规则与源码不匹配），终止任务并报告原因。

#### Step A2: Control 解析

- 引用 `src2linyaps.debian.analyze-control` → `python3 skills/src2linyaps.debian.analyze-control/scripts/init-control.py <control_file> --blacklist skills/src2linyaps.debian.analyze-control/runtime-depends-blacklist.json`
- 脚本直接收文件路径，不预读 control 全文；仅诊断时读片段。
- 输出完整 YAML（含 buildDepends + runtimeDepends）。

#### Step A3: Rules 分析

- 引用 `src2linyaps.debian.analyze-rules`。
- **A3.1 机械分析（脚本）**：`python3 skills/src2linyaps.debian.analyze-rules/scripts/analyze-rules.py <project_path> <debian_path> [control_yaml]` → 输出 `build_tool`、`build_args`、`baseline`、`resources`。
- **A3.2 LLM 语义分析**：只读 `debian/rules` 的 override 段（`override_dh_*`），不重复 A3.1 已由 `analyze-rules.py` 解析的机械结果；识别额外编译参数 → `extra_args`，输出完整 `build_section`。
- 合并 A3.1 + A3.2 → 最终 YAML（含 `build_section`、`build_tool`、`build_args`、`extra_args`、`baseline`、`resources`）。
- **A3.3 补丁迁移**（仅当 `debian/patches/series` 存在且含激活补丁时执行）：
  a. 执行 `python3 skills/src2linyaps.debian.analyze-rules/scripts/migrate-patches.py --project-path <project_path> --debian-path <debian_path> --build-tmp-dir <build_tmp_dir> --source-name <source_name> --package-id <package_id> --target-yaml <target_linglong.yaml>` → stdout YAML 含 `patches_applied`/`patches_failed`/`patch_commands`/`patches_dir`/`has_patches`（`--source-patches-dir`/`--patches-dir` 可选，默认从 `--debian-path/patches` 与 `--target-yaml` 父目录推导）
  b. `has_patches: false`（无 series、series 为空、native 包）→ 跳过 A3.3，build_section 不变，不影响后续流程
  c. `patches_failed` 非空 → LLM 读取 `patches_failed[].rej_content` 与 `patches_failed[].error`，按当前源码修改对应补丁文件（调整行号、更新上下文、拆分/合并 hunk），重跑 `migrate-patches.py --retry`
  d. 仍失败 → 跳过该补丁，记 `patch_skipped, <package_id>, <patch_name>` 警告，继续迁移其余补丁（非阻断）
  e. 将 `patch_commands` 前置注入 A3.2 输出的 `build_section`（`patch_commands + "\n" + build_section`）
  f. 验证通过的补丁文件已由脚本复制到 `<target_yaml_dir>/patches/`（与 `linglong.yaml` 同级）

#### Step A4: 工程生成

- 引用 `src2linyaps.debian.build-res-generate`，调用 `generate-linglong-yaml.py`：

```
python3 skills/src2linyaps.debian.build-res-generate/scripts/generate-linglong-yaml.py \
  --control-info <control_info.yaml> \
  --build-section "<build_section>" \
  --build-tool <tool_type> \
  --build-args '<build_args_json>' \
  --extra-args '<extra_args_string>' \
  --package-version <baseline> \
  --custom-deb-urls <custom_debs_urls.conf> \
  --output output/linglong.yaml
```

- **输出**：`output/linglong.yaml`（完整的玲珑构建配方）。
- **`--custom-deb-urls`**（可选）：当用户提供自定义 deb URL 配置文件时传入。
  配置文件格式见 `reference/custom_debs_urls_conf_format.md`。
  传入后 build 段注入 `bash /project/linglong/download_custom_debs.sh "${PREFIX}"`，
  脚本和配置文件复制到输出目录。未提供时不注入。

### 路径 B: fallback 源码分析

#### Step B1: 构建工具检测

- 引用 `src2linyaps.source.detect-tool` → `bash skills/src2linyaps.source.detect-tool/scripts/detect-build-tool.sh <project_path>`
- 输出构建工具类型 YAML。

#### Step B2: 编译参数提取

- 引用 `src2linyaps.source.analyze-args` → `python3 skills/src2linyaps.source.analyze-args/scripts/extract-build-args.py <project_path> <tool_type>`
- 输出最终 YAML（含 `tool_type`、`build_args`、`build_section`）。

#### Step B3: 输出工程生成

- 使用 `linglong-defaults.json` 的默认值（含 `build_section_fallback`），调用 `generate-linglong-yaml.py` 生成 `linglong.yaml`。
- **输出**：`output/linglong.yaml`。

### Phase 3: 输出校验与写入

1. **格式校验**：`python3 skills/src2linyaps.debian.build-res-generate/scripts/validate-linglong-yaml.py output/linglong.yaml --build-tool <tool_type> --schema skills/config/linglong-schema.yaml`；退出码 0 通过，非 0 输出错误列表并终止（见失败处理策略）。
2. **输出最终文件**：将 `linglong.yaml` 写入 `output/linglong.yaml`。
3. **输出路径**：将 `output/linglong.yaml` 路径交给用户。

## 失败处理策略

遇到失败时暂停并询问用户：

```
❌ 处理失败: <project_name>
错误原因: [具体错误信息]

请选择:
1. [跳过继续] - 记录失败，处理下一个任务
2. [重试] - 重新尝试当前任务
3. [停止任务] - 终止所有处理
4. [查看日志] - 查看详细错误日志
5. [手动修复] - 暂停等待手动修复后继续
```

| 场景 | 处理方式 |
|------|---------|
| **规则与源码不匹配**（test-deps 检测到构建依赖全不可用） | 终止任务并报告原因 |
| **子 Skill 执行失败** | 暂停并询问用户 |
| **配置缺失**（`agent-config.json` 不可读） | 使用合理的默认值 |
| **校验未通过**（validate-linglong-yaml 报错） | 输出错误列表并终止 |

## 注意事项

- 多架构：可在 CSV 中指定多行（不同架构）。
- 临时文件：处理完成后清理临时解压目录。
- 日志保存：所有测试与构建日志保存到 `data/` 目录。

## 开始处理

1. 确认输入（项目目录或 CSV）→ 2. 检测 `debian/` 目录存在性，选择处理路径 → 3. 按流程执行分析 → 4. 生成最终 `linglong.yaml` → 5. 输出结果路径。
