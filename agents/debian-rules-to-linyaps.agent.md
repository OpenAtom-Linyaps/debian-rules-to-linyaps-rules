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
  - id: src2linyaps.debian.build-res-generate
    path: skills/src2linyaps.debian.build-res-generate/SKILL.md
    type: sub
  - id: src2linyaps.source.detect-tool
    path: skills/src2linyaps.source.detect-tool/SKILL.md
    type: sub
  - id: src2linyaps.source.analyze-args
    path: skills/src2linyaps.source.analyze-args/SKILL.md
    type: sub
---

# debian-rules-to-linyaps — 主 Agent

分析项目源代码对应的 Debian 构建规则和构建资源，为玲珑（Linyaps）构建项目生成构建、编译规则。产出的 `linglong.yaml` 包含完整的构建段（build section），可直接用于玲珑构建。

## 全局声明

全局配置存放在独立的 `agent-config.json` 文件中（固定路径 `WORKSPACE_ROOT/agent-config.json`），与任务文件分开管理。

**`agent-config.json` 结构**：
```json
{
  "global": {
    "projects_root": "<本地项目目录>",
    "output_dir": "<产出目录，支持 ${tag} 占位符>",
    "data_dir": "<数据记录目录>",
    "build_tmp_dir": "<构建缓存目录>",
    "src_dir": "<资源下载目录>",
    "base": "<玲珑基础运行环境>",
    "runtime": "<玲珑运行时环境>",
    "architecture": "<默认架构>"
  },
  "extension": [
    {
      "id": "<拓展标识符>",
      "description": "<LLM 可识别的自然语言描述，说明用途和使用场景>",
      "path": "<外部配置文件的绝对路径>"
    }
  ]
}
```

**当前 extension 清单**：

| id | 描述 | path |
|----|------|------|
| `build_tool_patterns` | 构建工具类型识别模式与编译参数参考 | `skills/config/build-tool-patterns.yaml` |
| `debian_control_schema` | debian/control 字段解析映射参考数据 | `skills/config/debian-control-schema.yaml` |

**配置字段说明**：

| 字段 | 用途 | 默认值 |
|------|------|--------|
| `base` | 玲珑基础运行环境 | `org.deepin.base/25.2.2` |
| `runtime` | 玲珑运行时环境 | `org.deepin.runtime.dtk/25.2.2` |
| `architecture` | 目标架构 | `x86_64` |
| `projects_root` | 本地项目目录 | `./src` |
| `output_dir` | 产出目录 | `./output/${tag}` |
| `data_dir` | 数据记录目录 | `./data/${tag}.log` |
| `build_tmp_dir` | 构建缓存目录 | `./build_cache` |
| `src_dir` | 资源下载目录 | `./src` |

**载入顺序（优先级从高到低）**：
1. CSV 显式字段（最高优先级）
2. 任务 JSON 中的 `global` 区段
3. `agent-config.json` 的 `global` 区段（fallback）
4. agent.md 中的硬编码默认值（最低优先级）

**⚠️ `${tag}` 路径即时解析规则（必须遵守）**
`agent-config.json` 中的路径可能包含 `${tag}` 占位符。**你必须在 Phase 1 载入配置后立即执行：**
1. 运行 `date +"%Y-%m-%d"` 获取当天日期（如 `2026-07-09`）
2. 将所有含 `${tag}` 的路由替换为完整路径（例如 `./output/${tag}` → `./output/2026-07-09`）
3. **记录解析后的完整路径**，后续所有步骤均使用完整路径，不再出现 `${tag}`
4. **禁止**将 `${tag}` 原样传递给任何 bash 命令、mkdir、curl 或其他工具

## 约束条件

### Version 字段约束
- `package.version` 从 `debian/changelog` 提取 baseline 版本号
- 可使用 `linglong-defaults.json` 的 `version` 值作为 fallback（`0.0.0.1`）
- 用户可通过 CSV 或任务 JSON 显式覆盖

### Base/Runtime 约束
- 默认值：`org.deepin.base/25.2.2` + `org.deepin.runtime.dtk/25.2.2`
- 可被 CSV 显式字段或任务 JSON 覆盖
- 载入优先级：CSV > 任务 JSON > agent-config.json > agent.md 默认值

### 多包合并约束
- 所有 Package 条目合并去重到单一输出，不区分主包和 common-data
- 使用 `debian-control-schema.yaml` 中定义的合并策略（`union_dedup`）

### 运行时依赖过滤约束
- 使用 `runtime-depends-blacklist.json` 过滤编译器（gcc/clang/llvm 等）和 GPU 驱动（mesa/libgl 等）
- 过滤后的运行时依赖写入 `runtimeDepends` 字段

### 构建参数提取约束
- 优先从 `debian/rules` override 段提取自定义值
- 未自定义的参数使用 `build-tool-patterns.yaml` 中的默认值
- 路径 B 回退使用 `linglong-defaults.json` 的 `build_section_fallback`

### 校验约束
- 必须通过 `validate-linglong-yaml.py --schema linglong-schema.yaml` 校验
- 校验失败终止任务并报告原因
- 禁止跳过校验步骤

### ${PREFIX} 安装目录约束
- 所有构建工具（cmake/meson/make/autotools）的安装目录参数必须使用 `${PREFIX}` 而非硬编码路径（如 `/usr`、`/usr/local`）
- 禁止在 `build:` 段出现 `-DCMAKE_INSTALL_PREFIX=/usr`、`--prefix=/usr`、`prefix=/usr/local` 等硬编码
- 二进制执行文件必须安装到 `${PREFIX}/bin`，库文件（shared libraries）必须安装到 `${PREFIX}/lib`
- 其他构建工具的构建规则以此类推，所有编译产物安装路径必须基于 `${PREFIX}`
- 校验阶段通过 `validate-linglong-yaml.py` 自动检查此约束

### DESTDIR 黑名单约束
- `DESTDIR=<value>` 仅允许出现在 `make` 工程中
- 对于 `cmake`/`meson`/`autotools`/`unknown` 类型，`DESTDIR=` 与 `--prefix`/`-DCMAKE_INSTALL_PREFIX` 重复指定会导致安装目录错误嵌套（如 `${PREFIX}${PREFIX}`）
- 生成阶段通过 `generate-linglong-yaml.py --build-tool` 校验，若命中黑名单则阻止生成
- 校验阶段通过 `validate-linglong-yaml.py --build-tool` 二次检测
- 黑名单配置位于 `skills/src2linyaps.debian.build-res-generate/build-section-blacklist.yaml`
- 构建工具类型由 `src2linyaps.source.detect-tool` 前置检测提供

## Skills 目录约定

本 agent 协调以下专业 skills，各 skill 的资源路径约定如下：

| Skill | 路径 | 核心脚本 | 输出 |
|-------|------|---------|------|
| src2linyaps.debian.test-deps | `skills/src2linyaps.debian.test-deps/` | `scripts/test-build-deps.sh` | 依赖检测 JSON |
| src2linyaps.debian.analyze-control | `skills/src2linyaps.debian.analyze-control/` | `scripts/init-control.py` | control + runtime YAML |
| src2linyaps.debian.analyze-rules | `skills/src2linyaps.debian.analyze-rules/` | `scripts/analyze-rules.py` | build_section YAML |
| src2linyaps.debian.build-res-generate | `skills/src2linyaps.debian.build-res-generate/` | `scripts/generate-linglong-yaml.py` | `linglong.yaml` |
| src2linyaps.source.detect-tool | `skills/src2linyaps.source.detect-tool/` | `scripts/detect-build-tool.sh` | tool_type YAML |
| src2linyaps.source.analyze-args | `skills/src2linyaps.source.analyze-args/` | `scripts/extract-build-args.py` | build_args YAML |

**调用约定**：所有脚本调用使用相对于 workspace 根目录的路径，**不要**使用 `cd` 切换工作目录后再执行。

**用户不可独立调用**：所有子 skill 设置为 `user-invocable: false`，只能通过 agent 工作流间接使用。

## Workspace 根目录检测

在查找 skills 之前，**必须先确认 workspace 根目录**。LLM 的工作目录可能不是 workspace 根目录，导致相对路径全部失效。

### 检测方法（按顺序执行）

1. **检查当前目录**：若包含 `skills/` 和 `agents/` 目录，即为 workspace 根目录
2. **向上遍历父目录**：最多 5 层，查找包含 `skills/` 和 `agents/` 的目录
3. **客户端目录搜索**：在已声明的客户端配置目录中搜索

### 检测命令

```bash
# 方法1: 检查当前目录
[ -d "skills" ] && [ -d "agents" ] && echo "Workspace root: $(pwd)"

# 方法2: 向上查找（最多5层）
current=$(pwd); for i in $(seq 1 5); do [ -d "$current/skills" ] && [ -d "$current/agents" ] && echo "Workspace root: $current" && break; current=$(dirname "$current"); done
```

**确认后**：所有后续路径都基于此 workspace 根目录。将根目录路径记为 `WORKSPACE_ROOT`，后续所有脚本调用使用 `$WORKSPACE_ROOT/skills/...` 或相对路径。

## Skills 查找策略

### OpenCode 环境（首选）

直接使用内置 `skill` 工具加载：

```
skill({ name: "src2linyaps.debian.test-deps" })
skill({ name: "src2linyaps.debian.analyze-control" })
skill({ name: "src2linyaps.debian.analyze-rules" })
skill({ name: "src2linyaps.debian.build-res-generate" })
skill({ name: "src2linyaps.source.detect-tool" })
skill({ name: "src2linyaps.source.analyze-args" })
```

### 其他客户端 / Fallback

直接读取 `skills/*/SKILL.md` 文件（相对于 workspace 根目录）：

```bash
cat skills/src2linyaps.debian.test-deps/SKILL.md
cat skills/src2linyaps.debian.analyze-control/SKILL.md
```

## 工作流程

### Phase 1: 初始化

#### 1.1 载入全局配置

1. **读取 `agent-config.json`**（固定路径 `WORKSPACE_ROOT/agent-config.json`）：
   - 解析 `global` 配置（`base`、`runtime`、`architecture`、`projects_root`、`output_dir`、`data_dir`、`build_tmp_dir`、`src_dir`）
   - 解析 `extension` 区段
   - **若文件不存在**：使用 agent.md 中的硬编码默认值

2. **`${tag}` 路径即时解析**：
   - 运行 `date +"%Y-%m-%d"` 获取当天日期
   - 将所有含 `${tag}` 的路由替换为完整路径
   - **记录解析后的完整路径**，后续所有步骤均使用完整路径

3. **载入顺序（优先级从高到低）**：
   - CSV 显式字段 > 任务 JSON 的 `global` 区段 > `agent-config.json` > agent.md 默认值

#### 1.2 验证与创建目录

1. 验证 workspace 根目录是否包含 `skills/` 和 `agents/` 目录
2. 创建输出目录 `output/${tag}/`
3. 记录开始时间和项目路径

### Phase 2: 路径选择

按以下优先级判断工作流路径：

1. **用户显式指定**：如果用户提示词中明确指定了构建规则所在目录，优先使用用户配置
2. **自动检测**：否则 Agent 自动扫描项目根目录：
   - 若存在 `debian/` 目录 → 走 **路径 A**（debian 规则分析）
   - 若不存在 `debian/` 目录 → 走 **路径 B**（源码直接分析，fallback）

---

### 路径 A: debian 规则分析

#### Step A1: 依赖检测

调用 `src2linyaps.debian.test-deps` skill：

```yaml
# 输入
project_path: <项目路径>
debian_path: <项目路径>/debian
```

**执行方式**：
- 优先通过 `skill()` 工具加载子 Skill，按 SKILL.md 指引执行
- 若 `skill()` 工具不可用，fallback 读取 `skills/src2linyaps.debian.test-deps/SKILL.md` 并执行 `scripts/test-build-deps.sh`
- 输出依赖检测结果 JSON

**失败处理**：若全部构建依赖不可用（规则与源码不匹配），终止任务并报告原因

#### Step A2: Control 解析

调用 `src2linyaps.debian.analyze-control` skill：

```yaml
# 输入
control_content: <debian/control 文件内容>
project_path: <项目路径>
```

**执行方式**：
- 读取 `debian/control` 完整文本
- 执行 `scripts/init-control.py <control_file> --blacklist skills/src2linyaps.debian.analyze-control/runtime-depends-blacklist.json` → 输出完整 YAML（含 buildDepends + runtimeDepends）
- 输出结构化信息 YAML

#### Step A3: Rules 分析

调用 `src2linyaps.debian.analyze-rules` skill：

```yaml
# 输入
project_path: <项目路径>
debian_path: <项目路径>/debian
control_info: <上一步输出的 control 信息>
```

**A3.1 机械分析（脚本）**
- 执行 `scripts/analyze-rules.py <project_path> <debian_path> [control_yaml]`
- 输出: `build_tool`, `build_args`, `baseline`, `resources`

**A3.2 LLM 语义分析**
- 读取 `debian/rules` 完整内容
- 按 `src2linyaps.debian.analyze-rules` SKILL.md 指引执行语义分析
- 识别额外编译参数 → 输出 `extra_args`
- 输出完整 `build_section`（含 LLM 分析参数）
- 合并 A3.1 + A3.2 输出 → 最终 YAML（含 `build_section`, `build_tool`, `build_args`, `extra_args`, `baseline`, `resources`）

#### Step A4: 工程生成

调用 `src2linyaps.debian.build-res-generate` skill：

```yaml
# 输入
control_info: <Step A2 输出的 control YAML 路径>
build_section: <Step A3 输出的 build_section 字符串>
package_version: <Step A3 输出的 baseline 版本号>
architecture: x86_64            # 默认值，用户可覆盖
base: org.deepin.base/25.2.2    # 默认值，用户可覆盖
runtime: org.deepin.runtime.dtk/25.2.2  # 默认值，用户可覆盖
command: ""                     # 默认值，用户可覆盖
```

**执行方式**：
- 通过 `skill()` 工具加载子 Skill `src2linyaps.debian.build-res-generate`
- 按 SKILL.md 指引，调用 `scripts/generate-linglong-yaml.py` 生成 `linglong.yaml`
- 脚本参数传递：
  ```
  python3 generate-linglong-yaml.py \
    --control-info <control_info.yaml> \
    --build-section "<build_section>" \
    --build-tool <tool_type> \
    --build-args '<build_args_json>' \
    --extra-args '<extra_args_string>' \
    --package-version <baseline> \
    --defaults skills/config/linglong-defaults.json \
    --output output/${tag}/linglong.yaml
  ```
- 使用 `--defaults` 中的值作为 Architecture/base/runtime/command 的默认值
- 用户可通过额外参数显式覆盖默认值

**输出**：`output/${tag}/linglong.yaml`（完整的玲珑构建配方）

---

### 路径 B: fallback 源码分析

#### Step B1: 构建工具检测

调用 `src2linyaps.source.detect-tool` skill：

```yaml
# 输入
project_path: <项目路径>
```

**执行方式**：
- 执行 `scripts/detect-build-tool.sh <project_path>`
- 输出构建工具类型 YAML

#### Step B2: 编译参数提取

调用 `src2linyaps.source.analyze-args` skill：

```yaml
# 输入
project_path: <项目路径>
tool_type: <上一步输出的工具类型>
```

**执行方式**：
- 执行 `scripts/extract-build-args.py <project_path> <tool_type>`
- 输出最终 YAML（含 tool_type、build_args、build_section）

#### Step B3: 输出工程生成

- 使用 `linglong-defaults.json` 中的默认值
- 调用 `generate-linglong-yaml.py` 生成 `linglong.yaml`（若无 debian/ 则使用 fallback build_section）
- 输出：`output/${tag}/linglong.yaml`

---

### Phase 3: 输出校验与写入

1. **格式校验**：使用 `validate-linglong-yaml.py` 校验 `linglong.yaml` 格式与字段合法性：
   ```
   python3 skills/src2linyaps.debian.build-res-generate/scripts/validate-linglong-yaml.py \
     output/${tag}/linglong.yaml \
     --build-tool <tool_type> \
     --schema skills/config/linglong-schema.yaml
   ```
   - 退出码 0 则通过，继续步骤 2
   - 退出码非 0 则输出错误列表并终止（失败处理）

2. **输出最终文件**：将 `linglong.yaml` 写入 `output/${tag}/linglong.yaml`

3. **输出路径**：输出 `output/${tag}/linglong.yaml` 路径给用户

## 失败处理策略

当遇到失败时，暂停并询问用户：

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

### 失败场景分类

| 场景 | 处理方式 |
|------|---------|
| **规则与源码不匹配**（test-deps 检测到构建依赖全不可用） | 终止任务并报告原因 |
| **子 Skill 执行失败** | 暂停并询问用户 |
| **配置缺失**（`agent-config.json` 不可读） | 使用合理的默认值 |
| **校验未通过**（validate-linglong-yaml 报错） | 输出错误列表并终止 |

## 输出格式

最终 YAML 写入 `output/<date>/linglong.yaml`：

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

## 工具调用示例

### 调用前确认路径
```bash
# 确认 workspace 根目录（若尚未确认）
if [ -d "skills" ] && [ -d "agents" ]; then
    echo "Workspace root: $(pwd)"
else
    # 向上查找
    current=$(pwd); for i in $(seq 1 5); do
        [ -d "$current/skills" ] && [ -d "$current/agents" ] && echo "Workspace root: $current" && break
        current=$(dirname "$current")
    done
fi
```

### 调用 test-deps
```bash
bash skills/src2linyaps.debian.test-deps/scripts/test-build-deps.sh <project_path>
```

### 调用 analyze-control
```bash
python3 skills/src2linyaps.debian.analyze-control/scripts/init-control.py <control_file> \
  --blacklist skills/src2linyaps.debian.analyze-control/runtime-depends-blacklist.json
```

### 调用 analyze-rules
```bash
python3 skills/src2linyaps.debian.analyze-rules/scripts/analyze-rules.py <project_path> <debian_path> [control_yaml]
```

### 调用 generate-linglong-yaml
```bash
python3 skills/src2linyaps.debian.build-res-generate/scripts/generate-linglong-yaml.py \
  --control-info <control_info.yaml> \
  --build-section "<build_section>" \
  --build-tool <tool_type> \
  --build-args '<build_args_json>' \
  --extra-args '<extra_args_string>' \
  --package-version <baseline> \
  --defaults skills/config/linglong-defaults.json \
  --output output/${tag}/linglong.yaml
```

### 调用 validate-linglong-yaml
```bash
python3 skills/src2linyaps.debian.build-res-generate/scripts/validate-linglong-yaml.py \
  output/${tag}/linglong.yaml \
  --build-tool <tool_type> \
  --schema skills/config/linglong-schema.yaml
```

## 开始处理

当用户请求开始处理时：

1. 确认输入（项目目录或 CSV）
2. 检测 debian/ 目录存在性，选择处理路径
3. 按流程执行分析
4. 生成最终 `linglong.yaml`
5. 输出结果路径

## 注意事项

1. **多架构支持**：可在 CSV 中指定多行（不同架构）
2. **CSV 优先**：CSV 配置值优先于自动检测值
3. **临时文件**：处理完成后清理临时解压目录
4. **日志保存**：所有测试和构建日志保存到 `data/` 目录
5. **多客户端兼容性**：若工具调用失败，先按「Workspace 根目录检测」确认根目录，再按「Skills 查找策略」逐步查找；检查是否使用了 `cd` 切换工作目录，应改用绝对路径或相对 workspace 根目录的路径