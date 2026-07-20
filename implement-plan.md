# debian-rules-to-linyaps-rules 实现计划

## 阶段一：基础设施搭建

### 1.1 创建目录结构

```bash
mkdir -p agents
mkdir -p skills/src2linyaps.debian.test-deps
mkdir -p skills/src2linyaps.debian.analyze-control
mkdir -p skills/src2linyaps.debian.analyze-rules
mkdir -p skills/src2linyaps.source.detect-tool
mkdir -p skills/src2linyaps.source.analyze-args
mkdir -p skills/config
mkdir -p .opencode/skills
mkdir -p examples
mkdir -p tests
```

### 1.2 创建符号链接

```bash
ln -sf ../../skills/src2linyaps.debian.test-deps       .opencode/skills/src2linyaps.debian.test-deps
ln -sf ../../skills/src2linyaps.debian.analyze-control  .opencode/skills/src2linyaps.debian.analyze-control
ln -sf ../../skills/src2linyaps.debian.analyze-rules    .opencode/skills/src2linyaps.debian.analyze-rules
ln -sf ../../skills/src2linyaps.source.detect-tool      .opencode/skills/src2linyaps.source.detect-tool
ln -sf ../../skills/src2linyaps.source.analyze-args     .opencode/skills/src2linyaps.source.analyze-args
```

## 阶段二：核心文件编写

### 2.1 主 Agent — `agents/debian-rules-to-linyaps.agent.md`

**内容要点**：
| 区段 | 内容 |
|------|------|
| YAML frontmatter | `name`, `description`, `tools`(read/edit/search/execute/todo/skill), `permission.skill.*: allow` |
| 全局声明 | 引用 `agent-config.json` 配置，`${tag}` 路径解析规则 |
| Workspace 根目录检测 | 检查当前/父目录是否包含 `skills/` 和 `agents/` |
| Skills 查找策略 | 通过 `skill()` 工具加载子 Skill，fallback 直接读取 `skills/*/SKILL.md` |
| 工作流编排 | Phase1 初始化 → 判断路径 → **路径A**: test-deps → analyze-control → analyze-rules / **路径B**: detect-tool → analyze-args |
| 输出格式 | 统一 YAML 格式定义 |
| 失败处理 | 规则与源码不匹配时终止任务 |

### 2.2 子 Skill — 5 个 `skills/src2linyaps.*/SKILL.md`

统一前置格式：
```yaml
---
name: src2linyaps.debian.test-deps
description: > ...
user-invocable: false
---
```

各 Skill 需包含：
- **功能说明**：该模块的职责描述
- **触发场景**：什么情况下被调用
- **输入**：明确的输入数据结构
- **工作流程**：步骤化的执行指引
- **输出**：明确的输出数据格式
- **约束**：执行中的注意事项

#### 2.2.1 `src2linyaps.debian.test-deps`
- 克隆/下载项目源码
- 检查 `debian/control` 中 `Build-Depends` 字段内容
- 执行 `sudo apt build-dep` 安装依赖
- 输出：安装成功/失败状态 + 缺失或失败的依赖包列表

#### 2.2.2 `src2linyaps.debian.analyze-control`
- 解析 `debian/control` 中的 `Source:` 字段提取源码包名
- 解析 `Build-Depends:` 字段提取完整构建依赖列表
- 解析 `Description:` 等元信息字段
- 输出：pkgName, pkgDescription, Build-Depends 列表（结构化 JSON/YAML）

#### 2.2.3 `src2linyaps.debian.analyze-rules`
- 分析 `debian/rules` 中的 `dh` 命令序列和构建参数
- 解析 `debian/changelog` 提取 baselin 版本
- 分析 postinst/prerm 等 post 脚本的资源依赖
- 输出：完整 YAML（含构建工具类型、编译参数及默认值、debian baseline、源码包名）

#### 2.2.4 `src2linyaps.source.detect-tool`
- 扫描项目根目录识别构建配置文件
- 识别规则：
  - `CMakeLists.txt` → cmake
  - `meson.build` → meson
  - `Makefile` 或 `GNUmakefile` → make
  - `configure` 或 `configure.ac` → autotools
- 输出：构建工具类型

#### 2.2.5 `src2linyaps.source.analyze-args`
- 根据检测到的构建工具类型读取配置
- 解析可修改的编译参数：
  - cmake: `-DCMAKE_INSTALL_PREFIX=`, `-DCMAKE_BUILD_TYPE=` 等
  - meson: `-Dprefix=`, `-Dbuildtype=` 等
  - make: 读取 Makefile 中的 `prefix`, `DESTDIR` 等变量
- 输出：最终 YAML（含构建工具类型 + 编译参数及默认值）

### 2.3 参考数据 — `skills/config/`

#### `build-tool-patterns.yaml`
定义各构建工具的特征文件名和识别规则：
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

#### `debian-control-schema.yaml`
定义 `debian/control` 字段解析映射和默认值规则。

### 2.4 全局配置 — `agent-config.json`

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

## 阶段三：测试验证

### 3.1 测试场景准备

- `tests/test-debian-rules.sh`：准备一个带完整 debian 规则的项目，验证路径 A 全流程
- `tests/test-fallback.sh`：准备一个只有 CMakeLists.txt 的项目，验证路径 B 全流程
- `tests/test-mismatch.sh`：准备 debian 规则与源码不匹配的项目，验证约束终止逻辑

### 3.2 验证方式

- 加载 Agent → 输入项目路径 → 检查输出 YAML 的完整性和正确性
- 分别验证 5 个子 Skill 的独立输入/输出

## 阶段四：示例项目

- `examples/demo-project/`：包含 `debian/` 目录和源代码的演示项目，用于端到端测试
- `examples/demo-project-fallback/`：仅有 CMakeLists.txt 的演示项目

## 实现优先级

| 优先级 | 阶段 | 预计工作量 |
|--------|------|-----------|
| P0 | 阶段一：目录结构 + 符号链接 | 小 |
| P0 | 阶段二 2.1：主 Agent | 大 |
| P0 | 阶段二 2.2.1 ~ 2.2.3：路径 A 三个子 Skill | 大 |
| P1 | 阶段二 2.2.4 ~ 2.2.5：路径 B 两个子 Skill | 中 |
| P1 | 阶段二 2.3：参考数据 | 小 |
| P2 | 阶段二 2.4：agent-config.json | 小 |
| P2 | 阶段三：测试 | 中 |
| P3 | 阶段四：示例 | 小 |