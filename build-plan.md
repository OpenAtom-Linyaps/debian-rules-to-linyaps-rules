# debian-rules-to-linyaps-rules 构建计划

> 基于 `project-plan.md`、`implement-plan.md`、`skill.design.md` 以及用户讨论确认的最终方案。

---

## 一、项目目的

分析项目源代码对应的 debian 构建规则和构建资源，为玲珑构建项目生成构建、编译规则和通用资源（common-data）。

---

## 二、核心架构

**Agent + Sub-Skills** 两层架构：

- **Agent**（`agents/debian-rules-to-linyaps.agent.md`）：负责工作流编排、路径选择、子 Skill 调用、错误处理。YAML frontmatter 声明 skills 依赖，正文编排详细逻辑。
- **Sub-Skills**（`skills/src2linyaps.*/SKILL.md`）：每个子模块独立封装，带辅助脚本（`scripts/`），`user-invocable: false`，仅由 Agent 编排使用。

---

## 三、两套工作流

### 路径 A：带有 debian 构建规则的项目

```
debian-rules-test >> proj-info-analyze >> debian-rules-analyze
```

### 路径 B：不提供 debian 构建规则的项目（fallback）

```
src-type-analyze >> src-build-args-analyze
```

### 路径选择策略

1. 若用户提示词中明确指定了构建规则所在目录，优先使用用户配置
2. 否则 Agent 自动扫描源码目录，存在 `debian/` 则走路径 A，不存在则走路径 B

---

## 四、目录结构

```
debian-rules-to-linyaps-rules/
├── agents/
│   └── debian-rules-to-linyaps.agent.md        # 主 Agent
├── skills/
│   ├── src2linyaps.debian.test-deps/
│   │   ├── SKILL.md
│   │   └── scripts/
│   │       └── test-build-deps.sh
│   ├── src2linyaps.debian.analyze-control/
│   │   ├── SKILL.md
│   │   └── scripts/
│   │       └── parse-control.py
│   ├── src2linyaps.debian.analyze-rules/
│   │   ├── SKILL.md
│   │   └── scripts/
│   │       └── analyze-rules.py
│   ├── src2linyaps.source.detect-tool/
│   │   ├── SKILL.md
│   │   └── scripts/
│   │       └── detect-build-tool.sh
│   ├── src2linyaps.source.analyze-args/
│   │   ├── SKILL.md
│   │   └── scripts/
│   │       └── extract-build-args.py
│   └── config/
│       ├── build-tool-patterns.yaml
│       └── debian-control-schema.yaml
├── .opencode/
│   └── skills/                                    # 符号链接 → ../../skills/*
│       ├── src2linyaps.debian.test-deps         -> ../../skills/src2linyaps.debian.test-deps
│       ├── src2linyaps.debian.analyze-control   -> ../../skills/src2linyaps.debian.analyze-control
│       ├── src2linyaps.debian.analyze-rules     -> ../../skills/src2linyaps.debian.analyze-rules
│       ├── src2linyaps.source.detect-tool       -> ../../skills/src2linyaps.source.detect-tool
│       └── src2linyaps.source.analyze-args      -> ../../skills/src2linyaps.source.analyze-args
├── agent-config.json                               # 全局配置
├── build-plan.md                                   # 本文件：构建计划
├── project-plan.md                                 # 项目方案（已有）
├── implement-plan.md                               # 实现计划（已有）
├── skill.design.md                                 # 设计文档（已有）
├── src-examples/                                   # 测试用真实项目（已有）
│   ├── kate-cmake/                                 # 路径A：有 debian/，3个Package，CMake
│   ├── mame-makefile/                              # 路径B：无 debian/，Makefile
│   └── scrcpy-meson-build/                         # 路径B：无 debian/，Meson
└── tests/                                          # 测试用例
    ├── test-debian-rules.sh                        # 路径A 全流程测试
    ├── test-fallback.sh                            # 路径B 全流程测试
    └── test-mismatch.sh                            # 规则与源码不匹配测试
```

---

## 五、子 Skill 接口契约

### 路径 A（3 个子 Skill）

| 子 Skill | 命名 | 输入 | 输出 |
|----------|------|------|------|
| **debian-rules-test** | `src2linyaps.debian.test-deps` | 项目源码路径, `debian/` 目录 | 依赖可用性结果（`status` + `available_pkgs[]` + `missing_pkgs[]` + `raw_build_depends[]`） |
| **proj-info-analyze** | `src2linyaps.debian.analyze-control` | `debian/control` 文件内容 | `pkgName`, `pkgDescription`, `buildDepends[]`（多个 Package 条目合并去重） |
| **debian-rules-analyze** | `src2linyaps.debian.analyze-rules` | 项目源码, debian 规则目录 | 最终 YAML（含构建工具类型、编译参数及默认值、baseline、源码包名、合并后的 resources） |

### 路径 B（2 个子 Skill）

| 子 Skill | 命名 | 输入 | 输出 |
|----------|------|------|------|
| **src-type-analyze** | `src2linyaps.source.detect-tool` | 项目源码根目录 | 构建工具类型（cmake/meson/make/autotools） |
| **src-build-args-analyze** | `src2linyaps.source.analyze-args` | 构建配置文件 | 最终 YAML（含构建工具类型 + 编译参数及默认值） |

---

## 六、各文件详细设计

### 6.1 主 Agent — `agents/debian-rules-to-linyaps.agent.md`

**YAML frontmatter**：
```yaml
---
name: debian-rules-to-linyaps
description: >
  分析项目源代码对应的 debian 构建规则和构建资源，为玲珑构建项目生成构建、编译规则和通用资源。
tools:
  read: true; edit: true; search: true; execute: true; todo: true; skill: true
permission:
  skill: { "*": "allow" }
skills:
  - id: src2linyaps.debian.test-deps
    path: skills/src2linyaps.debian.test-deps/SKILL.md
    type: sub
  - id: src2linyaps.debian.analyze-control
    path: skills/src2linyaps.debian.analyze-control/SKILL.md
    type: sub
  - id: src2linyaps.debian.analyze-rules
    path: skills/src2linyaps.debian.analyze-rules/SKILL.md
    type: sub
  - id: src2linyaps.source.detect-tool
    path: skills/src2linyaps.source.detect-tool/SKILL.md
    type: sub
  - id: src2linyaps.source.analyze-args
    path: skills/src2linyaps.source.analyze-args/SKILL.md
    type: sub
---
```

**正文编排**（5 个 Phase）：

| Phase | 名称 | 内容 |
|-------|------|------|
| **Phase 0** | 全局声明 | 引用 `agent-config.json`，`${tag}` 路径实时解析（`date +"%Y-%m-%d"`），记录解析后完整路径 |
| **Phase 1** | 初始化 | 验证 workspace 根目录是否包含 `skills/` 和 `agents/`，创建输出目录 |
| **Phase 2** | 路径选择 | 按优先级：用户显式指定路径 → 自动扫描 `debian/` 目录存在性，决定走路径 A 或 B |
| **Phase 3A** | 路径 A | `skill(src2linyaps.debian.test-deps)` → `skill(src2linyaps.debian.analyze-control)` → `skill(src2linyaps.debian.analyze-rules)` |
| **Phase 3B** | 路径 B | `skill(src2linyaps.source.detect-tool)` → `skill(src2linyaps.source.analyze-args)` |
| **Phase 4** | 输出校验 | 校验 YAML 完整性，写入 `output/${tag}/`，输出最终路径 |

**Skills 加载策略**：
- 优先通过 `skill()` 工具加载子 Skill
- 若 `skill()` 不可用，fallback 直接读取 `skills/*/SKILL.md` 文件内容

**失败处理**：
- 若 debian 规则与源码不匹配，终止任务并报告原因
- 各子 Skill 执行失败时，暂停并询问用户

---

### 6.2 子 Skill — `src2linyaps.debian.test-deps`

**职责**：检测 `debian/control` 中 `Build-Depends` 的可用性，不实际安装。

**核心逻辑**（`test-build-deps.sh`）：
1. 读取 `debian/control` → 提取 `Build-Depends` 原始字段
2. 执行 `DEBIAN_FRONTEND=noninteractive apt-get build-dep --dry-run ./`
   - 退出码 0 → 解析 "The following NEW packages will be installed:" 输出列表 → `available_pkgs`
   - 退出码 ≠ 0 → 从 "E: Unable to locate package" 等错误中提取缺失包名 → `missing_pkgs`
3. 输出结构化结果：
   ```json
   {
     "status": "available" | "partial" | "unavailable",
     "available_pkgs": ["debhelper", "cmake", ...],
     "missing_pkgs": ["libfoo-dev", ...],
     "raw_build_depends": ["debhelper-compat (=13)", "cmake", ...]
   }
   ```

**输入**：项目源码路径, `debian/` 目录路径

**输出**：依赖可用性结构化数据

---

### 6.3 子 Skill — `src2linyaps.debian.analyze-control`

**职责**：解析 `debian/control`，提取项目信息，合并多个 Package 条目。

**核心逻辑**（`parse-control.py`）：
1. 解析 `debian/control` 中的 `Source:` 字段 → 提取源码包名
2. 解析 `debian/control` 中的 `Build-Depends:` 字段 → 提取完整构建依赖列表
3. 解析 `Description:` 等元信息字段
4. **遍历所有 Package 条目**，对多个 binary 包的信息做全量合并去重
5. 输出：
   ```yaml
   pkgName: kate
   pkgDescription: "Kate is a text editor for KDE"
   buildDepends:
     - debhelper-compat (= 13)
     - dh-sequence-kf6
     - cmake
     - ...
   ```

**关键设计**：
- 一个 `debian/control` 只允许一个 Source，但可能有多个 Package 条目
- `Build-Depends` 取并集去重
- 不再区分主包和 common-data，全部合并到同一个输出

---

### 6.4 子 Skill — `src2linyaps.debian.analyze-rules`

**职责**：分析构建规则，输出最终 YAML（含多包合并）。

**核心逻辑**（`analyze-rules.py`）：
1. 分析 `debian/rules` 中的 `dh` 命令序列和构建参数
2. 解析 `debian/changelog` 提取 baseline 版本
3. **关联扫描** `debian/*.install`、`debian/*.links`、`debian/*.docs`、`debian/*.manpages` 等文件，合并所有 binary 包的资源文件列表
4. 处理 `debian/rules` 中多 destdir 的 `dh_install`（如 `--destdir=debian/pkgA/`、`debian/pkgB/`）统一合并
5. 扫描 `debian/*.postinst`、`debian/*.prerm` 等各包 post 脚本，去重合并
6. 输出最终 YAML（无 `common-data` 字段）：
   ```yaml
   pkgName: kate
   pkgDescription: "Kate is a text editor for KDE"
   build_tool: cmake
   build_tool_type: cmake
   baseline: "25.04.3-2deepin1"
   build_depends:
     - debhelper-compat (= 13)
     - dh-sequence-kf6
     - cmake
   build_args:
     - name: CMAKE_INSTALL_PREFIX
       default: /usr
     - name: CMAKE_BUILD_TYPE
       default: Release
   resources:
     install:
       - src: usr/bin/kate
         dest: /usr/bin/
       - src: usr/share/kate/
         dest: /usr/share/
     manpages:
       - usr/share/man/man1/kate.1
   ```

---

### 6.5 子 Skill — `src2linyaps.source.detect-tool`

**职责**：扫描项目根目录，识别构建工具类型。

**核心逻辑**（`detect-build-tool.sh`）：
1. 读取 `build-tool-patterns.yaml` 获取特征文件标记
2. 扫描项目根目录，按优先级匹配：
   - `CMakeLists.txt` → cmake
   - `meson.build` → meson
   - `Makefile` 或 `GNUmakefile` → make
   - `configure` 或 `configure.ac` → autotools
3. 输出：
   ```yaml
   tool_type: cmake
   confidence: high
   ```

---

### 6.6 子 Skill — `src2linyaps.source.analyze-args`

**职责**：根据检测到的构建工具类型，读取配置提取可修改编译参数，输出最终 YAML。

**核心逻辑**（`extract-build-args.py`）：
1. 根据工具类型读取对应构建配置文件
2. 解析可修改的编译参数：
   - cmake: `CMakeLists.txt` 中的 `-DCMAKE_INSTALL_PREFIX=`, `-DCMAKE_BUILD_TYPE=` 等
   - meson: `meson_options.txt` 中的 `-Dprefix=`, `-Dbuildtype=` 等
   - make: `Makefile` 中的 `prefix`, `DESTDIR` 等变量
   - autotools: `configure` 中的 `--prefix=`, `--host=` 等
3. 输出最终 YAML：
   ```yaml
   build_tool: make
   build_tool_type: make
   build_args:
     - name: prefix
       default: /usr/local
     - name: DESTDIR
       default: ""
   ```

---

### 6.7 参考数据文件

#### `skills/config/build-tool-patterns.yaml`

```yaml
tools:
  cmake:
    markers: ["CMakeLists.txt"]
    args_prefix: "-D"
    common_args: ["CMAKE_INSTALL_PREFIX", "CMAKE_BUILD_TYPE"]
  meson:
    markers: ["meson.build"]
    args_prefix: "-D"
    common_args: ["prefix", "buildtype"]
  make:
    markers: ["Makefile", "GNUmakefile"]
    args_prefix: ""
    common_args: ["prefix", "DESTDIR"]
  autotools:
    markers: ["configure", "configure.ac"]
    args_prefix: ""
    common_args: ["prefix", "host"]
```

#### `skills/config/debian-control-schema.yaml`

定义 `debian/control` 字段解析映射和默认值规则。

---

### 6.8 全局配置 — `agent-config.json`

```json
{
  "global": {
    "output_dir": "./output/${tag}",
    "data_dir": "./data/${tag}.log",
    "build_tmp_dir": "./build_cache",
    "src_dir": "./src"
  },
  "extension": [
    {
      "id": "build_tool_patterns",
      "description": "构建工具类型识别模式与编译参数参考",
      "path": "skills/config/build-tool-patterns.yaml"
    },
    {
      "id": "debian_control_schema",
      "description": "debian/control 字段解析映射参考数据",
      "path": "skills/config/debian-control-schema.yaml"
    }
  ]
}
```

---

## 七、测试用例

### 测试项目（来自 `src-examples/`）

| 项目 | 路径 | 特征 |
|------|------|------|
| **kate-cmake** | 路径A | 有 `debian/`，3 个 Package 条目（kate/kate-data/kwrite），`debian/*.install` 文件，CMake 构建 |
| **mame-makefile** | 路径B | 无 `debian/`，纯 Makefile 构建 |
| **scrcpy-meson-build** | 路径B | 无 `debian/`，Meson + Gradle 构建 |

### 测试脚本

| 脚本 | 测试场景 | 验证点 |
|------|----------|--------|
| `tests/test-debian-rules.sh` | 路径A：kate-cmake 完整流程 | ① 3 包合并去重正确 ② `debian/*.install` 关联扫描 ③ `debian/rules` dh kf6 序列解析 ④ baseline 提取 ⑤ 输出 YAML 完整性 |
| `tests/test-fallback.sh` | 路径B：mame-makefile + scrcpy-meson-build | ① 自动检测 Makefile ② 自动检测 Meson ③ 对应构建参数提取正确性 |
| `tests/test-mismatch.sh` | 规则与源码不匹配场景 | ① 约束终止逻辑触发 ② 返回错误信息 |

### 验证方式

- 加载 Agent → 输入项目路径 → 检查输出 YAML 的完整性和正确性
- 分别验证 5 个子 Skill 的独立输入/输出

---

## 八、约束条件

1. 传入的原始项目必须包含 debian 构建规则或构建配置文件
2. 若传入的 debian 构建规则和源代码项目不匹配，则结束任务
3. 所有子 Skill 设置 `user-invocable: false`，只能通过 Agent 工作流间接调用
4. `test-build-deps` 使用 `apt-get build-dep --dry-run` 非交互式检测，不实际安装依赖
5. 多包场景：一个 source 构建多个 binary package 时，合并为单一输出，不再区分主包和 common-data

---

## 九、实施顺序

| 优先级 | 步骤 | 内容 | 涉及文件数 |
|--------|------|------|-----------|
| P0 | 1 | 创建目录结构 + 符号链接 | 1 个脚本 |
| P0 | 2 | `agent-config.json` + 两个 config yaml | 3 个 |
| P0 | 3 | `analyze-control` SKILL.md + `parse-control.py` | 2 个 |
| P0 | 4 | `analyze-rules` SKILL.md + `analyze-rules.py` | 2 个 |
| P0 | 5 | `test-deps` SKILL.md + `test-build-deps.sh` | 2 个 |
| P1 | 6 | `detect-tool` SKILL.md + `detect-build-tool.sh` | 2 个 |
| P1 | 7 | `analyze-args` SKILL.md + `extract-build-args.py` | 2 个 |
| P0 | 8 | 主 Agent `debian-rules-to-linyaps.agent.md` | 1 个 |
| P2 | 9 | 测试脚本 × 3 | 3 个 |
| P3 | 10 | 引用 `src-examples/` 已有项目 | 无需创建 |

---

## 十、决策记录

| 序号 | 议题 | 决策 |
|------|------|------|
| 1 | 路径选择策略 | 用户指定优先，否则 Agent 自动检测 |
| 2 | 子 Skill 是否带脚本 | 附脚本（`scripts/` 目录） |
| 3 | Agent 编排格式 | YAML frontmatter 声明 skills + 正文编排 |
| 4 | 多包合并策略 | 所有 Package 条目合并去重到单一输出，不区分主包/common-data |
| 5 | `debian/*.install` 等文件处理 | 由 `analyze-rules` 关联扫描 |
| 6 | 多包合并子 Skill | 不新增，增强现有 `analyze-control` 和 `analyze-rules` |
| 7 | 依赖检测方式 | `apt-get build-dep --dry-run` 非交互模拟 |
| 8 | 示例项目来源 | 使用 `src-examples/` 中已有真实项目，不新建 |