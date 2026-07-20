# debian-rules-to-linyaps-rules 最终项目方案

## 项目目的

分析项目源代码对应的 debian 构建规则和构建资源，为玲珑构建项目生成构建、编译规则和通用资源（common-data）。

## 核心架构

**Agent + Sub-Skills** 两层架构：

- **Agent**（`agents/debian-rules-to-linyaps.agent.md`）：负责工作流编排、路径选择、子 Skill 调用、错误处理
- **Sub-Skills**（`skills/src2linyaps.*/SKILL.md`）：每个子模块独立封装，`user-invocable: false`，仅由 Agent 编排使用

## 两套工作流

### 路径 A：带有 debian 构建规则的项目

```
debian-rules-test >> proj-info-analyze >> debian-rules-analyze
```

### 路径 B：不提供 debian 构建规则的项目（fallback）

```
src-type-analyze >> src-build-args-analyze
```

## 目录结构

```
debian-rules-to-linyaps-rules/
├── agents/
│   └── debian-rules-to-linyaps.agent.md        # 主 Agent：YAML frontmatter + 工作流编排
├── skills/
│   ├── src2linyaps.debian.test-deps/
│   │   └── SKILL.md                            # [子Skill 1] 测试 Build-Depends 安装
│   ├── src2linyaps.debian.analyze-control/
│   │   └── SKILL.md                            # [子Skill 2] 解析 debian/control
│   ├── src2linyaps.debian.analyze-rules/
│   │   └── SKILL.md                            # [子Skill 3] 分析构建规则，产出最终 YAML
│   ├── src2linyaps.source.detect-tool/
│   │   └── SKILL.md                            # [子Skill 4] fallback: 检测构建工具类型
│   ├── src2linyaps.source.analyze-args/
│   │   └── SKILL.md                            # [子Skill 5] fallback: 解析构建配置参数
│   └── config/
│       ├── build-tool-patterns.yaml            # CMake/Meson/Makefile/Autotools 识别模式
│       └── debian-control-schema.yaml          # debian/control 字段解析映射
├── .opencode/
│   └── skills/                                 # 符号链接 → ../../skills/*
│       ├── src2linyaps.debian.test-deps         -> ../../skills/src2linyaps.debian.test-deps
│       ├── src2linyaps.debian.analyze-control   -> ../../skills/src2linyaps.debian.analyze-control
│       ├── src2linyaps.debian.analyze-rules     -> ../../skills/src2linyaps.debian.analyze-rules
│       ├── src2linyaps.source.detect-tool       -> ../../skills/src2linyaps.source.detect-tool
│       └── src2linyaps.source.analyze-args      -> ../../skills/src2linyaps.source.analyze-args
├── agent-config.json                           # 全局配置（output_dir/data_dir 等）
├── skill.design.md                             # 设计文档（已有）
├── project-plan.md                             # 本文件：项目方案
├── implement-plan.md                           # 实现计划
├── examples/                                   # 示例项目
└── tests/                                      # 测试用例
```

## 子 Skill 接口契约

| 子 Skill | 命名 | 输入 | 输出 |
|----------|------|------|------|
| **debian-rules-test** | `src2linyaps.debian.test-deps` | 项目源码路径, `debian/` 目录 | Build-Depends 安装结果（成功/失败 + 缺失包列表） |
| **proj-info-analyze** | `src2linyaps.debian.analyze-control` | `debian/control` 文件内容 | pkgName, pkgDescription, Build-Depends 列表 |
| **debian-rules-analyze** | `src2linyaps.debian.analyze-rules` | 项目源码, `debian/rules`, post 脚本等 | 有效构建参数列表（含默认值）+ 最终 YAML |
| **src-type-analyze** | `src2linyaps.source.detect-tool` | 项目源码根目录 | 构建工具类型（cmake/meson/make/autotools） |
| **src-build-args-analyze** | `src2linyaps.source.analyze-args` | 构建配置文件（CMakeLists/Makefile/meson.build 等） | 可修改的配置参数（含默认值）+ 最终 YAML |

## 约束条件

1. 传入的原始项目必须包含 debian 构建规则或构建配置文件
2. 若传入的 debian 构建规则和源代码项目不匹配，则结束任务
3. 所有子 Skill 设置 `user-invocable: false`，只能通过 Agent 工作流间接调用