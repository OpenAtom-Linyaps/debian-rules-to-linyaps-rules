# debian-rules-to-linyaps-rules

分析项目源代码对应的 Debian 构建规则和构建资源，为如意玲珑（Linyaps）构建项目生成构建、编译规则和通用资源。

## 架构

**Agent + Sub-Skills** 两层架构，由 OpenCode Agent 编排，6 个不可用户直接调用的子 Skill 各自独立封装。

```
┌─────────────────────────────────────────────────┐
│  debian-rules-to-linyaps (Agent)                │
│  ┌───────────────────────────────────────────┐  │
│  │ Phase 1: 初始化 (配置加载 + 目录验证 +     │  │
│  │           ${tag} 路径解析)                │  │
│  │ Phase 2: 路径选择 (用户指定 / 自动检测)    │  │
│  │ Phase 3: 执行 + 输出校验与写入             │  │
│  │   Path A: debian/ 存在时                   │  │
│  │   Path B: fallback (无 debian/)            │  │
│  └───────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
         │                          │
         ▼                          ▼
  ┌─────────────┐          ┌───────────────┐
  │  路径 A     │          │   路径 B      │
  │ 有 debian/  │          │ 无 debian/    │
  ├─────────────┤          ├───────────────┤
  │① test-deps  │          │① detect-tool  │
  │② analyze-   │          │② analyze-args │
  │  control    │          │③ 工程生成      │
  │③ analyze-   │          └───────────────┘
  │  rules      │
  │④ 工程生成   │
  └─────────────┘
```

### Multica 多智能体架构

项目提供 `for-multica/` 目录，支持 [Multica](https://multica.dev) 多智能体平台集成：

```
┌─────────────────────────────────────────────────────────┐
│ debian-rules-to-linyaps (Agent - Multica 版)            │
│  ┌───────────────────────────────────────────────────┐  │
│  │ Step 1-2: 配置加载 + Git 仓库初始化               │  │
│  │ Step 3:   路径选择 + 分析 + 生成                  │  │
│  │ Step A6:  Git 提交 + 指派 packer（Path A）       │  │
│  │ Step B4:  Git 提交 + 指派 packer（Path B）       │  │
│  │ Step 4-6:  结果记录 + Issue 状态更新              │  │
│  └───────────────────────────────────────────────────┘  │
└──────────────────────┬──────────────────────────────────┘
                       │ multica issue comment @mention
                       ▼
┌─────────────────────────────────────────────────────────┐
│ linyaps-packer-1 / linyaps-packer-2                     │
│ 接收 @mention → 执行 ll-builder build → 导出 → 推送    │
└─────────────────────────────────────────────────────────┘
```

详见 `for-multica/agent.md`。

## 工作流

### 路径 A — 有 `debian/` 构建规则的项目

| 阶段 | 子 Skill | 职责 | 辅助脚本 |
|------|----------|------|----------|
| A1 | `src2linyaps.debian.test-deps` | 检测 `Build-Depends` 可用性（非交互式 dry-run） | `test-build-deps.sh` |
| A2 | `src2linyaps.debian.analyze-control` | 解析 `debian/control`，多包合并去重；基于 apt 仓库解析运行时依赖 | `init-control.py` |
| A3 | `src2linyaps.debian.analyze-rules` | 分析 rules/changelog/install 等，输出 build_section | `analyze-rules.py` |
| A4 | `src2linyaps.debian.build-res-generate` | 合并 control + build_section + 默认值，生成 `linglong.yaml` | `generate-linglong-yaml.py` |

### 路径 B — 无 `debian/` 的项目（fallback）

| 阶段 | 子 Skill | 职责 | 辅助脚本 |
|------|----------|------|----------|
| B1 | `src2linyaps.source.detect-tool` | 扫描项目根目录识别构建工具类型 | `detect-build-tool.sh` |
| B2 | `src2linyaps.source.analyze-args` | 从构建配置文件提取编译参数 | `extract-build-args.py` |
| B3 | — | 使用 fallback 默认值生成 `linglong.yaml` | `generate-linglong-yaml.py` |

### 路径选择策略

1. **用户显式指定** — 若提示词中明确指定构建规则目录，优先使用
2. **自动检测** — 存在 `debian/` → 路径 A，否则 → 路径 B

## 目录结构

```
├── agents/
│   └── debian-rules-to-linyaps.agent.md     # 主 Agent 编排文件
├── for-multica/                              # Multica 多智能体集成
│   ├── agent-config.json                     # Multica 变体配置
│   ├── agent.md                              # Multica 工作流 agent
│   └── scripts/
│       └── check-agent-status.sh             # Agent 状态查询脚本
├── skills/
│   ├── config/
│   │   ├── build-tool-patterns.yaml          # 构建工具识别模式参考数据
│   │   ├── debian-control-schema.yaml        # debian/control 字段解析映射参考
│   │   └── linglong-defaults.json            # 玲珑构建默认配置
│   │   └── linglong-schema.yaml              # 玲珑 YAML 字段合法性约束
│   ├── src2linyaps.debian.test-deps/         # [子 Skill] 依赖可用性检测
│   │   ├── SKILL.md
│   │   └── scripts/test-build-deps.sh
│   ├── src2linyaps.debian.analyze-control/   # [子 Skill] debian/control 解析
│   │   ├── SKILL.md
│   │   ├── runtime-depends-blacklist.json     # 运行时依赖黑名单（编译器/Mesa 等）
│   │   └── scripts/
│   │       ├── init-control.py              # [统一入口] 解析 control + 查询运行时依赖（编排 parse-control 与 resolve-runtime-deps）
│   │       ├── parse-control.py
│   │       └── resolve-runtime-deps.py        # 基于 apt-cache 查询运行时依赖
│   ├── src2linyaps.debian.analyze-rules/     # [子 Skill] 构建规则 + 资源扫描
│   │   ├── SKILL.md
│   │   └── scripts/analyze-rules.py
│   ├── src2linyaps.debian.build-res-generate/ # [子 Skill] 玲珑 YAML 生成
│   │   ├── SKILL.md
│   │   └── scripts/
│   │       ├── generate-linglong-yaml.py
│   │       └── validate-linglong-yaml.py
│   ├── src2linyaps.source.detect-tool/       # [子 Skill] 构建工具类型检测
│   │   ├── SKILL.md
│   │   └── scripts/detect-build-tool.sh
│   └── src2linyaps.source.analyze-args/      # [子 Skill] 编译参数提取
│       ├── SKILL.md
│       └── scripts/extract-build-args.py
├── .opencode/skills/                         # 符号链接 → ../../skills/*
├── agent-config.json                         # 全局配置
└── tests/
    ├── test-debian-rules.sh                  # 路径 A 全流程测试
    ├── test-fallback.sh                      # 路径 B 全流程测试
    └── test-mismatch.sh                      # 规则与源码不匹配测试
```

## 配置

`agent-config.json` 全局配置（标准版；Multica 版配置详见 `for-multica/` 目录）：

```json
{
  "global": {
    "projects_root": "./src",
    "output_dir": "./output/${tag}",
    "data_dir": "./data/${tag}.log",
    "build_tmp_dir": "./build_cache",
    "src_dir": "./src",
    "base": "org.deepin.base/25.2.2",
    "runtime": "org.deepin.runtime.dtk/25.2.2",
    "architecture": "x86_64"
  },
  "extension": [...]
}
```

`${tag}` 使用 `date +"%Y-%m-%d"` 实时解析。

### Multica 版配置

`for-multica/agent.md` 顶部声明 `AGENT_CONFIG_PATH` 变量指向 `for-multica/agent-config.json`，所有下游 skill 通过 `agent_config_path` 参数接收该路径，集中管理配置入口。改路径只需修改 `agent.md` 顶部一行声明。`agent-config.json` 包含 `global`、`extension`、`assignment` 三个区段。

## 输出格式

最终 YAML 写入 `output/${tag}/final-${pkgName || projectName}.yaml`：

```yaml
pkgName: kate
pkgDescription: "Kate is a text editor for KDE"
build_tool: cmake
build_tool_type: cmake
baseline: "4:25.04.3-2deepin1"
build_depends:
  - debhelper-compat (= 13)
  - dh-sequence-kf6
  - cmake
build_args:
  - name: CMAKE_INSTALL_PREFIX
    default: ${PREFIX}
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

## 构建工具检测优先级

1. `CMakeLists.txt` → **cmake**
2. `meson.build` → **meson**
3. `Makefile` / `GNUmakefile` → **make**
4. `configure` / `configure.ac` → **autotools**
5. 无匹配 → **unknown**

## 测试

```bash
# 路径 A 全流程测试（kate-cmake：3 包合并、cmake 检测、baseline 提取）
bash tests/test-debian-rules.sh

# 路径 B 全流程测试（MAME makefile + scrcpy meson）
bash tests/test-fallback.sh

# 规则与源码不匹配场景测试
bash tests/test-mismatch.sh
```

## 约束条件

| 议题 | 决策 |
|------|------|
| 多包合并 | 所有 Package 条目合并去重到单一输出，不区分主包和 common-data |
| 依赖检测 | `DEBIAN_FRONTEND=noninteractive apt-get build-dep --dry-run`，不实际安装 |
| 子 Skill 可见性 | 全部 `user-invocable: false`，仅由 Agent 编排调用 |
| 构建参数提取 | 优先从 `debian/rules` override 段提取自定义值，否则使用默认值 |
| 资源扫描 | 合并所有 `*.install` / `*.links` / `*.docs` / `*.manpages` 文件，去重 |
| 运行时依赖过滤 | `resolve-runtime-deps.py` 支持 `--blacklist` 参数，从 JSON 文件加载黑名单包名，过滤编译器（gcc/clang/llvm 等）和 GPU 驱动（mesa/libgl 等）避免写入 `runtimeDepends` |
| Version 字段 | 从 `debian/changelog` 提取 baseline 版本号，fallback 使用 `linglong-defaults.json` |
| Base/Runtime | 默认 `org.deepin.base/25.2.2` + `org.deepin.runtime.dtk/25.2.2`，支持 CSV/JSON 覆盖 |
| 输出校验 | 必须通过 `validate-linglong-yaml.py --schema linglong-schema.yaml` 校验 |
| `${PREFIX}` 安装目录 | `build:` 段所有安装目录参数必须使用 `${PREFIX}` 而非硬编码的 `/usr`/`/usr/local`。`generate-linglong-yaml.py` 会自动替换常见硬编码路径为 `${PREFIX}`（安全网），`validate-linglong-yaml.py` 再校验残留 |

## Multica 集成

`for-multica/` 目录提供 Multica 多智能体平台集成：

| 文件 | 说明 |
|------|------|
| `for-multica/agent.md` | Multica 工作流 agent（声明 `AGENT_CONFIG_PATH` 变量，注入 `agent_config_path` 参数给所有下游 skill） |
| `for-multica/agent-config.json` | Multica 配置（含 `projects_repo`、`workspace`、`assignment` 等） |
| `for-multica/scripts/check-agent-status.sh` | Agent 状态查询脚本（热备方案） |

multica 工作流在标准分析流程末端增加：
1. **Git 仓库初始化**：强制要求 `projects_repo`，自动 clone + 推送权限验证
2. **Git 提交**：校验通过后提交 `CI_ll_*` 工程到仓库
3. **指派 packer**：通过 multica issue comment @mention 通知 `linyaps-packer-*` 智能体执行实际构建
4. **Issue 状态更新**：全部成功→审查完成 / 部分→部分完成 / 全失败→阻塞
