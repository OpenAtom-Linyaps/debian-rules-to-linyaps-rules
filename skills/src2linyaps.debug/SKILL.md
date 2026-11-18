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
argument-hint: '<layer_path> <problem_desc>'
user-invocable: true
tools:
  read: true; edit: true; search: true; execute: true; todo: true; skill: true
permission:
  skill: { "*": "allow" }
---

# src2linyaps.debug — 调试纠正 SKILL

分析纠正已有玲珑（Linyaps）构建工程。用户通过提示词注入已有构建工程打包出的 layer + 问题描述，本 skill 解压 layer 进行诊断，修复通过调用内部 skills 完成，完成后默认指派 `linyaps-packer` 重新打包。

## 设计核心

- **纯分析**：本 skill 本体只做「解压 layer → 对照分析 → 问题诊断」，不做修复实现。
- **修复调用具体 skills**：修复动作通过 `skill()` 调用 `skills/` 下的内部 skills 完成；common res 补齐由本 skill 直接落盘（无专属内部 skill）。
- **修复后指派 packer**：复用 `linyaps-src-init-dispatch` 的 `assign_packer` action（默认）；用户指定「不指派」时直接结束。

## 目录约定

- 本 skill 脚本：`skills/src2linyaps.debug/scripts/`
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
| `debian_path` | string | 否 | 额外提供的 debian 构建资源目录 |
| `agent_config_path` | string | 否 | 指派 packer 时指向的 `agent-config.json` |

## 内部 skills 清单与用途

以下为修复 workflow 中可调用的内部 skills（均位于 `skills/` 下）：

| Skill | 路径 | 用途（debug 修复时可调用场景） |
|-------|------|------------------------------|
| `src2linyaps.debian.test-deps` | `skills/src2linyaps.debian.test-deps/` | 校验 `Build-Depends` 可用性（修复 buildext.build_depends 前探测） |
| `src2linyaps.debian.analyze-control` | `skills/src2linyaps.debian.analyze-control/` | 解析 debian/control，合并 buildDepends/runtimeDepends（修复 `buildext` 依赖段） |
| `src2linyaps.debian.analyze-rules` | `skills/src2linyaps.debian.analyze-rules/` | 分析 debian/rules → build_section、build_tool、resources（修复 build 规则错误，比对产物） |
| `src2linyaps.debian.build-res-generate` | `skills/src2linyaps.debian.build-res-generate/` | 生成/重新生成 `linglong.yaml` + 校验（`generate-linglong-yaml.py` / `validate-linglong-yaml.py`） |
| `src2linyaps.source.detect-tool` | `skills/src2linyaps.source.detect-tool/` | 检测构建工具类型（cmake/meson/make/autotools），修复 build 段工具错误 |
| `src2linyaps.source.analyze-args` | `skills/src2linyaps.source.analyze-args/` | 提取编译参数与默认值（修复 configure/cmake 参数） |
| `linyaps-git-workflow` | `skills/linyaps-git-workflow/` | Git 提交/推送修复后的工程（可选，调试修正落地） |
| `linyaps-src-init-dispatch` | `skills/linyaps-src-init-dispatch/` | Multica 指派分发（debug 修复完成后指派 packer 节点） |

> **授权说明**：`linyaps-src-init-dispatch` 原约束「仅 debian-rules-to-linyaps agent 调用」。本 skill 属同一 workflow 体系的 debug 环节，特此在本文档显式授权其 `assign_packer` 调用场景，其他 action（`update_issue_status` / `check_agent_status`）不在本 skill 授权范围内。

## 工作流程（四阶段）

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
| common res 补齐 | 直接编辑 `files_res/` + `$PREFIX` 对应路径（遵循规范） | 本 skill 落盘 |
| 修复后二次校验 | `src2linyaps.debian.build-res-generate` | `validate-linglong-yaml.py`（见下） |
| 修复落地提交 | `linyaps-git-workflow` | commit + push（若已绑定仓库） |

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
- 退出码 0 → 校验通过，继续阶段四
- 退出码非 0 → 输出错误列表，按错误修复后重新校验，直至通过或判定无法修复

### 阶段四 · 指派 packer（默认）

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

## 输出

修复报告：
- 诊断问题（问题类型 + 定位 + 依据）
- 调用的 skill
- 改动 before/after
- 补齐 common res 清单
- 校验结果
- 指派结果 / 结束标记
