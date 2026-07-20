---
name: src2linyaps.debian.analyze-control
description: >
  解析 debian/control 文件，提取源码包名、构建依赖列表、描述信息等结构化数据。
  处理多个 Package 条目的全量合并去重。
user-invocable: false
---

## 功能说明

解析 `debian/control` 中的字段，提取项目基本信息：
- `Source:` → 源码包名 (`pkgName`)
- `Build-Depends:` / `Build-Depends-Arch:` / `Build-Depends-Indep:` → 构建依赖列表（并集去重）
- `Description:` → 项目描述
- 所有 `Package:` 条目名称

## 触发场景

由主 Agent (`debian-rules-to-linyaps`) 在路径 A 工作流中编排调用，在执行完 `src2linyaps.debian.test-deps` 后执行。

## 输入

| 名称 | 类型 | 描述 |
|------|------|------|
| control_content | string | `debian/control` 文件的完整文本内容 |
| project_path | string | 项目源码根目录路径 |

## 工作流程

1. 接收 `debian/control` 文件内容
2. 解析 `Source:` 字段 → 提取源码包名
3. 解析 `Build-Depends:` 字段 → 提取构建依赖列表
4. 解析 `Build-Depends-Arch:` 和 `Build-Depends-Indep:` 字段（若存在）
5. 遍历所有 `Package:` 条目，收集 binary 包名称
6. 对多个 Package 条目的构建依赖做并集去重
7. 解析 `Description:` 字段（取第一个 Package 条目的描述）
8. 输出结构化结果

## 输出

```yaml
pkgName: kate
pkgDescription: "Kate is a text editor for KDE"
buildDepends:
  - debhelper-compat (= 13)
  - dh-sequence-kf6
  - cmake (>= 3.16~)
  - extra-cmake-modules
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