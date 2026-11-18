---
name: src2linyaps.debian.build-res-generate
description: >
  基于 analyze-control 输出的依赖信息和 analyze-rules 输出的 build 段，
  结合模板和默认值配置，生成完整的 linglong.yaml 玲珑构建配方。
user-invocable: false
---

## 功能说明

接收 `analyze-control` 的结构化输出（含 `pkgName`、`pkgDescription`、`buildDepends`、`runtimeDepends`）
和 `analyze-rules` 输出的 `build_section` 构建脚本，结合默认值配置，合并生成符合玲珑规范的
`linglong.yaml` 构建配方文件。

## 触发场景

由主 Agent (`debian-rules-to-linyaps`) 在路径 A 工作流末尾编排调用，在 `src2linyaps.debian.analyze-rules`
执行之后调用，作为最终产出步骤。

## 输入

| 名称 | 类型 | 描述 | 来源 |
|------|------|------|------|
| `control_info` | dict | `pkgName`, `pkgDescription`, `buildDepends[]`, `runtimeDepends[]`, `binaryPackages[]` | `analyze-control` 输出 |
| `build_section` | string | 构建脚本内容（shell 命令），写入 `build:` 字段 | `analyze-rules` 输出 |
| `package_version` | string | 包版本号 | Agent 从 `debian/changelog` baseline 提取 |
| `architecture` | string | 玲珑架构（默认 `x86_64`） | `defaults.json` |
| `base` | string | base 镜像 | `defaults.json` |
| `runtime` | string | runtime 镜像 | `defaults.json` |
| `command` | string | 启动命令，按空格切割为 YAML 数组元素 | `defaults.json` |
| `build_tool` | string | 构建工具类型（`cmake`/`meson`/`make`/`autotools`/`unknown`），由 `detect-tool` 前置检测提供 | `detect-tool` 输出 |
| `agent_config_path` | string | `agent-config.json` 的绝对路径，由主 agent 在 Step 1 解析后传入 | 主 agent |

## 工作流程

1. 加载 `analyze-control` 输出的 control_info YAML
2. 根据 `buildDepends` 是否非空决定是否含 `build_depends` 段
3. 加载 `skills/config/linglong-defaults.json` 获取默认值
4. 按优先级解析各字段：CLI 参数 > defaults JSON > 硬编码默认值
5. 对 `buildDepends` 剥离版本约束（`cmake (>= 3.16~)` → `cmake`）
6. 对 `build_section` 执行参考检查（必需命令是否存在、禁用参数是否出现），缺失命令打印 `[warn]`，禁用参数阻断流程
7. 构建完整 YAML 结构并写入输出文件

## 输出

写入 `output/${tag}/linglong.yaml`，格式示例（含 buildDepends）：

```yaml
# SPDX-FileCopyrightText: 2023 UnionTech Software Technology Co., Ltd.
#
# SPDX-License-Identifier: LGPL-3.0-or-later

version: "25.4.3.2"

package:
  id: "kate"
  name: "kate"
  version: "25.4.3.2"
  kind: app
  architecture: x86_64
  description: "powerful text editor"

base: org.deepin.base/25.2.2

runtime: org.deepin.runtime.dtk/25.2.2

buildext:
  apt:
    build_depends:
    - debhelper-compat
    - cmake
    depends:
    - libc6
    - libcurl4

command:
- "kate"
- "--new"
- "file.txt"

build: |
  cmake -B build-linglong -DCMAKE_INSTALL_PREFIX=${prefix} ...
```

不含 buildDepends 时，`buildext.apt` 下仅有 `depends` 段，无 `build_depends`。

## 约束

- 不生成 `sources:` 段（由用户或上层工具按需补充）
- `build_depends` 条目自动剥离版本约束（玲珑 apt 插件需求）
- 若 `build_section` 为空，使用 `defaults.json` 中的 `build_section_fallback`
- 脚本使用 `skills/config/linglong-defaults.json` 作为默认值参考
- 使用 `scripts/generate-linglong-yaml.py` 辅助生成
- 使用 `scripts/validate-linglong-yaml.py` 验证生成结果格式
- `${PREFIX} 安装目录约束`：`build:` 字段中所有安装目录路径必须使用 `${PREFIX}`（大写）而非硬编码的 `/usr`。脚本 `generate-linglong-yaml.py` 会自动将 `${prefix}`（小写）替换为 `${PREFIX}`，并通过正则匹配将常见硬编码路径（如 `-DCMAKE_INSTALL_PREFIX=/usr`、`DESTDIR=/usr`、`--prefix=/usr`、`PREFIX=/usr/local` 等）替换为 `${PREFIX}`，作为 LLM 生成的 `build_section` 的安全网层
- `Build 段参考约束`：脚本通过 `referance/common-building-rules.yaml` 对 build 段进行双重检查：
  - **必需命令检查**：build 段必须包含该工具类型的规范构建命令（如 cmake 需有 `cmake ... -DCMAKE_INSTALL_PREFIX=...`、构建命令、安装命令）。缺失命令打印 `[warn]` 提示，不阻断流程。支持 `one_of` 多选匹配（如 cmake 构建可用 `make`/`ninja`/`cmake --build`）。
  - **禁用参数检查**：build 段禁止出现黑名单参数（如 cmake 工程中的 `DESTDIR=`）。检测到禁用参数时打印 `ERROR` 并阻断流程（exit 1）。
  - **命令拆分规则**：先合并 `\` 续行，再按 `&&`/`;`/`||`/`\n` 拆分为独立命令，逐条匹配。`make && make install` 与 `make` + `make install` 分行两种写法均可正确识别。

## 默认值配置 (`skills/config/linglong-defaults.json`)

```json
{
  "base": "org.deepin.base/25.2.2",
  "runtime": "org.deepin.runtime.dtk/25.2.2",
  "architecture": "x86_64",
  "version": "0.0.0.1",
  "command": "bash",
  "build_section_fallback": "cp -rf /project/binary/* ${prefix}/\n..."
}
```

取值优先级: CLI 显式参数 > defaults JSON > 硬编码默认值