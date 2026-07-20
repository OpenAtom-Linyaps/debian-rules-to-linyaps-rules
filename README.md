# debian-rules-to-linyaps-rules

分析项目源代码对应的 Debian 构建规则和构建资源，为玲珑（Linyaps）构建项目生成构建、编译规则和通用资源。

## 架构

**Agent + Sub-Skills** 两层架构，由 OpenCode Agent 编排，5 个不可用户直接调用的子 Skill 各自独立封装。

```
┌─────────────────────────────────────────────────┐
│  debian-rules-to-linyaps (Agent)                │
│  ┌───────────────────────────────────────────┐  │
│  │ Phase 0: 全局声明 (agent-config.json)      │  │
│  │ Phase 1: 初始化 (目录验证 + 输出目录创建)    │  │
│  │ Phase 2: 路径选择 (用户指定 / 自动检测)     │  │
│  │ Phase 3A: 路径 A (debian/ 存在时)          │  │
│  │ Phase 3B: 路径 B (fallback)               │  │
│  │ Phase 4: 输出校验与写入                    │  │
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
  │  control    │          └───────────────┘
  │③ analyze-   │
  │  rules      │
  └─────────────┘
```

## 工作流

### 路径 A — 有 `debian/` 构建规则的项目

| 步骤 | 子 Skill | 职责 | 辅助脚本 |
|------|----------|------|----------|
| 1 | `src2linyaps.debian.test-deps` | 检测 `Build-Depends` 可用性（非交互式 dry-run） | `test-build-deps.sh` |
| 2 | `src2linyaps.debian.analyze-control` | 解析 `debian/control`，多包合并去重 | `parse-control.py` |
| 3 | `src2linyaps.debian.analyze-rules` | 分析 rules/changelog/install 等，输出最终 YAML | `analyze-rules.py` |

### 路径 B — 无 `debian/` 的项目（fallback）

| 步骤 | 子 Skill | 职责 | 辅助脚本 |
|------|----------|------|----------|
| 1 | `src2linyaps.source.detect-tool` | 扫描项目根目录识别构建工具类型 | `detect-build-tool.sh` |
| 2 | `src2linyaps.source.analyze-args` | 从构建配置文件提取编译参数 | `extract-build-args.py` |

### 路径选择策略

1. **用户显式指定** — 若提示词中明确指定构建规则目录，优先使用
2. **自动检测** — 存在 `debian/` → 路径 A，否则 → 路径 B

## 目录结构

```
├── agents/
│   └── debian-rules-to-linyaps.agent.md     # 主 Agent 编排文件
├── skills/
│   ├── config/
│   │   ├── build-tool-patterns.yaml          # 构建工具识别模式参考数据
│   │   └── debian-control-schema.yaml        # debian/control 字段解析映射参考
│   ├── src2linyaps.debian.test-deps/         # [子 Skill] 依赖可用性检测
│   │   ├── SKILL.md
│   │   └── scripts/test-build-deps.sh
│   ├── src2linyaps.debian.analyze-control/   # [子 Skill] debian/control 解析
│   │   ├── SKILL.md
│   │   └── scripts/parse-control.py
│   ├── src2linyaps.debian.analyze-rules/     # [子 Skill] 构建规则 + 资源扫描
│   │   ├── SKILL.md
│   │   └── scripts/analyze-rules.py
│   ├── src2linyaps.source.detect-tool/       # [子 Skill] 构建工具类型检测
│   │   ├── SKILL.md
│   │   └── scripts/detect-build-tool.sh
│   └── src2linyaps.source.analyze-args/      # [子 Skill] 编译参数提取
│       ├── SKILL.md
│       └── scripts/extract-build-args.py
├── .opencode/skills/                         # 符号链接 → ../../skills/*
├── agent-config.json                         # 全局配置
├── tests/
│   ├── test-debian-rules.sh                  # 路径 A 全流程测试
│   ├── test-fallback.sh                      # 路径 B 全流程测试
│   └── test-mismatch.sh                      # 规则与源码不匹配测试
└── src-examples/
    ├── kate-cmake/                           # 路径 A: 3 个 Package, CMake
    ├── mame-makefile/                        # 路径 B: Makefile
    └── scrcpy-meson-build/                   # 路径 B: Meson
```

## 配置

`agent-config.json` 全局配置：

```json
{
  "global": {
    "output_dir": "./output/${tag}",
    "data_dir": "./data/${tag}.log",
    "build_tmp_dir": "./build_cache",
    "src_dir": "./src"
  }
}
```

`${tag}` 使用 `date +"%Y-%m-%d"` 实时解析。

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

## 关键设计决策

| 议题 | 决策 |
|------|------|
| 多包合并 | 所有 Package 条目合并去重到单一输出，不区分主包和 common-data |
| 依赖检测 | `DEBIAN_FRONTEND=noninteractive apt-get build-dep --dry-run`，不实际安装 |
| 子 Skill 可见性 | 全部 `user-invocable: false`，仅由 Agent 编排调用 |
| 构建参数提取 | 优先从 `debian/rules` override 段提取自定义值，否则使用默认值 |
| 资源扫描 | 合并所有 `*.install` / `*.links` / `*.docs` / `*.manpages` 文件，去重 |