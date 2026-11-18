---
name: src2linyaps.constraints
description: >
  【debian-rules-to-linyaps】通用构建约束的唯一权威。承载本 workflow 全部 skills 共享的
  构建/校验约束（${PREFIX} 安装目录、DESTDIR 黑名单、多包合并、运行时依赖存在性核验、校验契约）。
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

## 使用方式
- **主 agent**：初始化阶段调用 `skill({ name: "src2linyaps.constraints" })` 一次，后续步骤引用本 SKILL 约束即可。
- **子 skill**：以一行引用本 SKILL，不展开上述约束正文。
