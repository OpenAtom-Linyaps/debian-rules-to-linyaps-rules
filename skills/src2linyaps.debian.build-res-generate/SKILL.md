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
| `build_args` | list of dict | 构建参数（从 `analyze-rules` 机械分析获取） | `analyze-rules` 输出 |
| `extra_args` | string | 额外编译参数（LLM 语义分析 `debian/rules` 获取） | `analyze-rules` 输出 |
| `defaults_path` | string | `linglong-defaults.json` 的绝对路径（`extension.linglong_defaults`），由主 agent 解析 | 主 agent |
| `schema_path` | string | `linglong-schema.yaml` 的绝对路径（`extension.linglong_schema`），由主 agent 解析 | 主 agent |
| `reference_path` | string | `common-building-rules.yaml` 的绝对路径，默认自动定位到 skill 内 `reference/` | 主 agent |

## 工作流程

1. 加载 `analyze-control` 输出的 control_info YAML
2. 根据 `buildDepends` 是否非空决定是否含 `build_depends` 段
3. 加载 `skills/config/linglong-defaults.json` 获取默认值
4. 按优先级解析各字段：CLI 参数 > defaults JSON > 硬编码默认值
5. 对 `buildDepends` 剥离版本约束（`cmake (>= 3.16~)` → `cmake`）
6. 构建 build section：
   a. 若 `--build-section` 提供 → 使用 LLM 自定义构建段
   b. 否则 → 从 `reference/common-building-rules.yaml` 按工具类型生成规范模板
   c. 注入 `build_args`（非空参数替换 configure 行中同名值）
   d. 追加 `extra_args` 到 configure 命令行末尾
   e. 对照 reference 补充缺失的必选命令
   f. 检查 forbidden patterns，命中则阻断
7. 路径规范化（`${prefix}` → `${PREFIX}`、硬编码路径替换）
8. 追加 `touch ${PREFIX}/.linyaps_genius` 和 `chmod -R 755 ${PREFIX}`
9. 构建完整 YAML 结构并写入输出文件
10. 源码编译项目（build_tool ∈ cmake/meson/make/autotools）默认注入 clang：build 段前加
    `export CC="clang"`/`export CXX="clang++"`，build_depends 加 clang/lld/ccache，depends 加 libomp5

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
- **存在性校验（Issue 55）**：apt 仓库存在性校验由 `src2linyaps.debian.analyze-control` 同源持有（`depends.py`）。**Agent 在本 skill 生成 `buildext.apt.depends` 之前，应先调用 analyze-control 做存在性校验**；`runtimeDepends` 中不存在于 apt 仓库的包一律剔除，禁止写入 `depends`。本 skill 不做跨 skill 直接 import。
- `${PREFIX} 安装目录约束`：脚本 `generate-linglong-yaml.py` 自动将 `${prefix}`（小写）替换为 `${PREFIX}`，并通过正则替换常见硬编码路径（如 `-DCMAKE_INSTALL_PREFIX=/usr`、`DESTDIR=/usr`、`--prefix=/usr`、`PREFIX=/usr/local` 等）为 `${PREFIX}`，作为 LLM 生成的 `build_section` 的安全网层。安装子目录规范化：二进制 → `${PREFIX}/bin`、库 → `${PREFIX}/lib`、通用资源 → `${PREFIX}/share`，生成阶段自动修正错误子目录（打印 `[normalize]`），校验阶段阻断错误子目录；映射规则定义在 `reference/common-building-rules.yaml` 的 `install_dir_mapping` 键
- `Clang 默认编译`：源码编译项目（`build_tool` ∈ cmake/meson/make/autotools）默认使用 clang——
  build 段最前注入 `export CC="clang"`、`export CXX="clang++"`；`buildext.apt.build_depends` 追加 `clang`/`lld`/`ccache`，
  `depends` 追加 `libomp5`。生成/校验均参照 `reference/example-with-clang.linglong.yaml`。
  `build_tool` 为 `unknown`（二进制拷贝 fallback）不注入 clang。
  若用户 prompt 显式声明不用 clang 或使用 gcc 编译，主 agent 调用脚本时传 `--no-clang`
  关闭默认注入（此时不加 export CC/CXX，也不追加 clang/lld/ccache/libomp5）。
- `补丁构建依赖`：`build_section` 含 `patch -p1` 命令时（补丁由 `migrate-patches.py` 注入），
  `buildext.apt.build_depends` 自动追加 `patch`（容器内执行 `patch -p1` 需要 `patch` 包，未必预装），
  去重后追加，参照 clang 追加模式。宿主系统需预装 `quilt`（`migrate-patches.py` 用 `quilt push` 验证补丁）。
- `Build 段参考约束`：`reference/common-building-rules.yaml` 同时用于**生成**和**校验**：

  - **生成阶段**：脚本通过 `common-building-rules.yaml` 生成规范构建命令模板，注入 `build_args` 和 `extra_args` 参数，补充缺失的必选命令
  - **校验阶段**：对最终 build section 执行双重检查：
    - **必需命令检查**：build 段必须包含该工具类型的规范构建命令。缺失命令自动从参考补充，并打印 `[supplement]` 提示
    - **禁用参数检查**：build 段禁止出现黑名单参数（如 cmake 工程中的 `DESTDIR=`）。检测到禁用参数时打印 `ERROR` 并阻断流程（exit 1）
    - **命令拆分规则**：先合并 `\` 续行，再按 `&&`/`;`/`||`/`\n` 拆分为独立命令，逐条匹配

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

> 上下文效率：通用规则见 `src2linyaps.constraints` SKILL §7。本 skill 特有：生成的 `linglong.yaml` 不回读全文；校验只取退出码与错误列表。
