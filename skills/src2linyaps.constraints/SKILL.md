---
name: src2linyaps.constraints
description: >
  【debian-rules-to-linyaps】通用构建约束的唯一权威。承载本 workflow 全部 skills 共享的
  构建/校验约束与运行期操作契约、上下文效率规则（${PREFIX} 安装目录、DESTDIR 黑名单、
  多包合并、运行时依赖存在性核验、校验契约、运行期操作契约、上下文效率）。
  由主 agent 在初始化阶段一次性载入，各子 skill 引用本 SKILL 而非各自复述。
user-invocable: false
---

# src2linyaps.constraints — 通用构建约束

本 SKILL 是 `debian-rules-to-linyaps` 工作流构建/校验约束的**唯一权威定义**。
主 agent 在 Phase 1 / 步骤 1 一次性载入本 SKILL，各子 skill 与生成脚本以本 SKILL 为准，**不再重复展开下述约束**。

## 约束契约

### 1. `${PREFIX}` 安装目录
- 所有构建工具（cmake/meson/make/autotools）的安装目录参数必须使用 `${PREFIX}`，禁止硬编码 `/usr`、`/usr/local`。
- 二进制 → `${PREFIX}/bin`，库 → `${PREFIX}/lib`，通用资源 → `${PREFIX}/share`，其余产物基于 `${PREFIX}`。
- `generate-linglong-yaml.py` 自动将 `${prefix}`（小写）与常见硬编码路径替换为 `${PREFIX}`，作为安全网层；`validate-linglong-yaml.py` 自动检测残留硬编码。

### 2. DESTDIR 黑名单
- `DESTDIR=<value>` 仅允许出现在 `make` 工程。
- cmake/meson/autotools/unknown 类型禁用 `DESTDIR=`（与 `--prefix`/`-DCMAKE_INSTALL_PREFIX` 重复会导致 `${PREFIX}${PREFIX}` 嵌套）。
- 生成与校验阶段均通过 `--build-tool` 检测；黑名单配置 `skills/src2linyaps.debian.build-res-generate/build-section-blacklist.yaml`。

### 3. 多包合并
- 所有 `Package:` 条目（含主包与 common-data）合并去重到单一输出，不拆分。
- 合并策略见 `skills/config/debian-control-schema.yaml`（`union_dedup`）。

### 4. 运行时依赖存在性核验（Issue 55）
- 写入 `depends` / `buildext.apt.depends` 前，必须逐包 `apt-cache show` 核验，**不存在即剔除**，禁止写入。
- 核验能力由 `src2linyaps.debian.analyze-control`（`scripts/depends.py` 的 `package_exists()`）持有；其他 skill 需要时由 agent 调用该 skill，禁止跨 skill 直接 import。

### 5. 校验契约
- 生成的 `linglong.yaml` 必须通过 `validate-linglong-yaml.py --schema linglong-schema.yaml --build-tool <tool>`，退出码非 0 视为失败。
- `linglong-defaults.json` 为默认值（base/runtime/architecture/command/version）的权威来源。

## 6. 运行期操作契约

- **路径解析（Phase 1 一次性）**：调用方显式传入 `agent_config_path`；启动时解析并校验绝对 `WORKSPACE_ROOT`、`agent_config_path`、`skills_root` 及 workspace/extension 路径；脚本调用不依赖 cwd。
- **skill 固定路径**：skills 固定位于 `WORKSPACE_ROOT/skills/<name>/SKILL.md`，**无需搜索或遍历**。
- **禁止 `cd`**：所有脚本调用使用相对 `WORKSPACE_ROOT` 或绝对路径，禁止 `cd` 切换工作目录后再执行。
- **加载方式**：优先 `skill({ name: "<name>" })`；不可用时 fallback 按需 `cat skills/<name>/SKILL.md`，不批量预读。
- **用户不可独立调用**：除 `src2linyaps.debug`（`user-invocable: true`）外，所有子 skill 均为 `user-invocable: false`，只能经 agent 工作流间接调用。
- **配置取值优先级**：CSV 显式字段 > 任务 JSON 的 `global` > `agent-config.json` 的 `global` > agent 默认值；`agent-config.json` 字段与取值以其自身为准，agent 不内联 JSON 结构。
- **多客户端兼容**：工具调用失败时先确认 `WORKSPACE_ROOT`（须同时含 `skills/` 与 `agents/`），再按固定路径 fallback 读取 SKILL.md，并检查是否误用 `cd`。

## 7. 上下文效率（统一）

- 脚本 stdout 为结构化 YAML/JSON：直接以输出文件路径或管道传递给下一步，**禁止** `cat` 全量回读入 context。
- 长字段（`runtimeDepends`、`buildDependsAlternatives`、`resources`、`files`）以文件路径传递；仅需人工判断时读相关片段。
- 脚本失败诊断：只读 stderr 末尾 ≤100 行定位原因，不重放完整 stdout。
- `debian/control`、`debian/rules` 同一文件在一次任务中至多读取一次；A3.2 只读 override 段，不重复 A1–A3.1 已解析的机械结果。
- Skill 按需单个加载，不批量预读全部 SKILL.md。

## 使用方式
- **主 agent**：初始化阶段调用 `skill({ name: "src2linyaps.constraints" })` 一次，后续步骤引用本 SKILL 约束即可。
- **子 skill**：以一行引用本 SKILL，不展开上述约束正文。
- **子 skill / agent**：运行期操作与上下文效率一律引用 §6/§7，不各自复述。
