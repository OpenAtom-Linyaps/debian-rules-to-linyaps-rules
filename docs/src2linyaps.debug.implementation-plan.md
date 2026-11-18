# src2linyaps.debug 实现方案

独立 agent debug skill，用于分析纠正已有玲珑（Linyaps）构建工程。用户通过提示词注入已有构建工程打包出的 layer + 问题描述，skill 解压 layer 进行诊断，修复通过调用内部 skills 完成，完成后默认指派 linyaps-packer 重新打包。

## 设计核心

- **纯分析**：debug skill 本体只做「解压 layer → 对照分析 → 问题诊断」，不做修复实现。
- **修复调用具体 skills**：修复动作通过 `skill()` 调用 `skills/` 下的内部 skills 完成。
- **修复后指派 packer**：复用 `linyaps-src-init-dispatch` 的 `assign_packer` action。

## 可复用的内部资源（仅限 `skills/` 下）

| 内部资源 | 路径 | 用途 |
|---------|------|------|
| `validate-linglong-yaml.py` | `skills/src2linyaps.debian.build-res-generate/scripts/` | 修复后校验 schema/黑名单/`${PREFIX}`/common-building-rules |
| `generate-linglong-yaml.py` | 同上 `scripts/` | 用纠正后的 build_section/control 重新生成 `linglong.yaml` |
| `common-building-rules.yaml/.md` | `skills/src2linyaps.debian.build-res-generate/referance/` | 构建规则参考（生成+校验双用途） |
| `analyze-rules.py` | `skills/src2linyaps.debian.analyze-rules/scripts/` | 机械分析 debian rules，辅助定位 build 规则错误 |
| `linglong-schema.yaml` | `skills/config/` | 字段合法性约束 |
| `linglong-defaults.json` | `skills/config/` | 默认 base/runtime 等 |

## 内部 skills 清单与用途（修复 workflow 调用声明）

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

## 交付物

1. `skills/src2linyaps.debug/SKILL.md`（新建）
2. `agents/debian-rules-to-linyaps.agent.md`（注册 + 表格）
3. `for-multica/agent.md`（表格）
4. `README.md`（skills 清单）

---

## 1. `skills/src2linyaps.debug/SKILL.md`

### frontmatter

```yaml
name: src2linyaps.debug
description: >
  分析纠正已有玲珑构建工程：解压打包 layer + 问题描述，诊断 build 规则、
  common res 缺失等问题；修复通过调用内部 skills 完成；完成后默认指派
  linyaps-packer 重新打包（可选不指派直接结束）。
user-invocable: true
tools:
  read: true; edit: true; search: true; execute: true; todo: true; skill: true
permission:
  skill: { "*": "allow" }
```

### 输入

| 名称 | 类型 | 必填 | 描述 |
|------|------|------|------|
| `layer_path` | string | 是 | 已有构建工程打包出的 layer 文件 |
| `problem_desc` | string | 是 | 问题描述（构建失败/运行异常/common res 缺失等） |
| `project_path` | string | 否 | 被纠正的工程目录（含 `linglong.yaml`） |
| `debian_path` | string | 否 | 额外提供的 debian 构建资源目录 |
| `agent_config_path` | string | 否 | 指派 packer 时指向的 `agent-config.json` |

### 工作流程（四阶段）

**阶段一 · 解压 layer**

```bash
ll-builder extract <layer_path> <workdir>
```

解压后定位 `<workdir>/files`，即 `linglong.yaml` 声明的 `$PREFIX` 内容。
参考：`examples/ll-builder.command.refence.md`。

**阶段二 · 对照分析（纯分析，不改文件）**

- 读工程 `linglong.yaml`（package.id/name/version、command、build、buildext、modules）
- 对照 `files/` 结构（bin/lib/share）+ `problem_desc`，判定问题类型：
  - build 规则错误（工具类型 / DESTDIR / 硬编码 `/usr` / 参数缺失）
  - command 指向的可执行文件缺失
  - common res 缺失（`share/applications/*.desktop`、`share/icons/hicolor/**`、`share/metainfo|appdata`、`share/locale`）
  - buildext 依赖缺失/多余
  - yaml 格式 / base / runtime 错误
- `debian_path` 存在时，用 `analyze-rules.py` 辅助比对 debian 产物与 `files/`
- 输出结构化诊断清单

**阶段三 · 修复（调用具体内部 skills）**

| 诊断问题 | 调用的内部 skill | 核心动作 |
|---------|-----------------|---------|
| build 工具类型错误 | `src2linyaps.source.detect-tool` | 检测正确工具类型 |
| build 参数/configure 错误 | `src2linyaps.source.analyze-args` + `src2linyaps.debian.analyze-rules` | 提取/重生成 build 段 |
| 重新生成 linglong.yaml | `src2linyaps.debian.build-res-generate` | `generate-linglong-yaml.py` |
| buildext 依赖问题 | `src2linyaps.debian.analyze-control` + `src2linyaps.debian.test-deps` | 修正 buildDepends/runtimeDepends |
| common res 补齐 | 直接编辑 `files_res/` + `$PREFIX` 对应路径（遵循规范） | debug skill 落盘 |
| 修复后二次校验 | `src2linyaps.debian.build-res-generate` | `validate-linglong-yaml.py --schema ... --build-tool ... --reference common-building-rules.yaml` |
| 修复落地提交 | `linyaps-git-workflow` | commit + push（若已绑定仓库） |

**阶段四 · 指派 packer（默认）**

- **默认**：修复 + 校验通过后，调用 `linyaps-src-init-dispatch` 的 `assign_packer`

```json
{
  "action": "assign_packer",
  "pkgName": "...",
  "project_dir": "CI_ll_...",
  "arch": "x86_64",
  "workflow_type": "debian-rules-to-linyaps",
  "data_dir": "...",
  "workspace": "linyaps",
  "agent_config_path": "..."
}
```

- **可选**：若用户指定「不指派」，则修复校验通过后直接结束任务，输出修复报告。

### 约束

- `files/` 即 `$PREFIX`
- 禁止硬编码 `/usr`（遵循 `${PREFIX}` 约束）
- 修复后必须通过 `validate-linglong-yaml.py` 校验
- 临时解压目录处理完清理
- `linyaps-src-init-dispatch` 原约束注明「仅 debian-rules-to-linyaps agent 调用」；本 skill 属同一 workflow 体系 debug 环节，在 SKILL.md 中显式授权其 `assign_packer` 调用场景

### 输出

修复报告：
- 诊断问题
- 调用的 skill
- 改动 before/after
- 补齐 common res 清单
- 校验结果
- 指派结果 / 结束标记

---

## 2. `agents/debian-rules-to-linyaps.agent.md`

frontmatter `skills:` 追加：

```yaml
- id: src2linyaps.debug
  path: skills/src2linyaps.debug/SKILL.md
  type: sub
```

「Skills 目录约定」表追加一行，标注 `user-invocable: true`（独立调试入口）。

## 3. `for-multica/agent.md`

Skills 目录约定表追加 `src2linyaps.debug` 行（含用途说明）。

## 4. `README.md`

skills 清单（目录结构 + 工作流）补充 `src2linyaps.debug` 说明。
