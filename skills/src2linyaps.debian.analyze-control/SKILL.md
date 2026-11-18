---
name: src2linyaps.debian.analyze-control
description: >
   解析 debian/control 文件，提取源码包名、构建依赖列表、描述信息等结构化数据。
   处理多个 Package 条目的全量合并去重。基于 apt 仓库解析构建依赖的运行时依赖。
user-invocable: false
---

## 功能说明

解析 `debian/control` 中的字段，提取项目基本信息：
- `Source:` → 源码包名 (`pkgName`)
- `Build-Depends:` / `Build-Depends-Arch:` / `Build-Depends-Indep:` → 构建依赖列表（并集去重），处理 `|`（或）语法，`buildDepends` 中取每个 or-group 的第一个选项，`buildDependsAlternatives` 中保留完整替代组
- `Description:` → 项目描述
- 所有 `Package:` 条目名称
- 基于 apt 仓库解析 Build-Depends 各包的运行时依赖 → `runtimeDepends`

## 触发场景

由主 Agent (`debian-rules-to-linyaps`) 在路径 A 工作流中编排调用，在执行完 `src2linyaps.debian.test-deps` 后执行。

## 输入

| 名称 | 类型 | 描述 |
|------|------|------|
| control_content | string | `debian/control` 文件的完整文本内容 |
| project_path | string | 项目源码根目录路径 |
| agent_config_path | string | `agent-config.json` 的绝对路径，由主 agent 在 Step 1 解析后传入 |

## 工作流程

1. 接收 `debian/control` 文件内容
2. 解析 `Source:` 字段 → 提取源码包名
3. 解析 `Build-Depends:` 字段 → 提取构建依赖列表
4. 解析 `Build-Depends-Arch:` 和 `Build-Depends-Indep:` 字段（若存在）
5. 遍历所有 `Package:` 条目，收集 binary 包名称
6. 对多个 Package 条目的构建依赖做并集去重
7. 解析 `Description:` 字段（取第一个 Package 条目的描述）
8. 基于 apt 仓库逐包查询 Build-Depends 的运行时依赖：
- 调用 `scripts/parse-control.py <control_file>` → 输出 YAML（含 buildDepends）
  - 调用 `scripts/resolve-runtime-deps.py <control_yaml> --blacklist runtime-depends-blacklist.json` → 输出 YAML（含 runtimeDepends，已过滤黑名单包）
   - Agent 合并两个 YAML 结果
9. 输出结构化结果

## 输出

```yaml
pkgName: kate
pkgDescription: "Kate is a text editor for KDE"
buildDepends:
  - debhelper-compat (= 13)
  - dh-sequence-kf6
  - cmake (>= 3.16~)
  - extra-cmake-modules
  - libjack-jackd2-dev
  - ...
buildDependsAlternatives:  # 或语法替代组，每组中任一包可用即可
  - - libjack-jackd2-dev
    - libjack-dev
runtimeDepends:        # 基于 apt 仓库解析的运行时依赖
  - libc6
  - libcurl4
  - libarchive13
  - qt6-base-dev
  - ...
binaryPackages:
  - kate
  - kate-data
  - kwrite
```

## 约束

- 一个 `debian/control` 只允许一个 `Source:` 字段
- 可能有多个 `Package:` 条目，构建依赖取并集去重
- 不再区分主包和 common-data，全部合并到同一个输出
- 依赖项中的版本约束（如 `(= 13)`、`(>= 3.16~)`）完整保留
- 使用 `scripts/parse-control.py` 辅助解析
- 使用 `scripts/resolve-runtime-deps.py` 查询运行时依赖
- 运行时依赖通过 `LC_ALL=C apt-cache depends` 查询，需要系统已配置 apt 仓库
- 若 `apt-cache` 不可用或查询失败，`runtimeDepends` 输出空列表（不影响主流程）
- 支持黑名单机制：`runtime-depends-blacklist.json` 中列出的包名会被从 `runtimeDepends` 中剔除，避免编译器、Mesa 驱动等非应用核心组件被错误写入
- `buildDependsAlternatives` 中的每个替代组表示一组可互换的包（Debian `|` 语法），`buildDepends` 中已包含每组第一个选项。LLM 应根据实际情况选择最适合的选项写入最终配置，例如优先选择在 apt 源中可用的包，或选择与项目架构更匹配的包