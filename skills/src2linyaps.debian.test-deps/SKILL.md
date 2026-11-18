---
name: src2linyaps.debian.test-deps
description: >
  检测 debian/control 中 Build-Depends 的可用性，使用 apt-get build-dep --dry-run
  非交互式检测，不实际安装任何依赖包。
user-invocable: false
---

## 功能说明

读取 `debian/control` 中的 `Build-Depends` 字段，通过 `apt-get build-dep --dry-run` 模拟安装检测依赖可用性。
输出依赖包的状态：可用、部分缺失或完全不可用。

## 触发场景

由主 Agent (`debian-rules-to-linyaps`) 在路径 A 工作流中编排调用，作为第一个子 Skill 执行。

## 输入

| 名称 | 类型 | 描述 |
|------|------|------|
| project_path | string | 项目源码根目录路径 |
| debian_path | string | `debian/` 目录路径 |

## 工作流程

1. 读取 `debian/control` → 提取 `Build-Depends` 原始字段内容
2. 在项目目录下执行 `DEBIAN_FRONTEND=noninteractive apt-get build-dep --dry-run ./`
   - 退出码 0 → 解析 "The following NEW packages will be installed:" 输出列表 → `available_pkgs`
   - 退出码 ≠ 0 → 从 "E: Unable to locate package" 等错误中提取缺失包名 → `missing_pkgs`
3. 输出结构化结果

## 输出

```json
{
  "status": "available" | "partial" | "unavailable",
  "available_pkgs": ["debhelper", "cmake", ...],
  "missing_pkgs": ["libfoo-dev", ...],
  "raw_build_depends": ["debhelper-compat (=13)", "cmake", ...]
}
```

## 约束

- 使用 `apt-get build-dep --dry-run` 非交互式检测，不实际安装依赖
- 需要 root 权限执行 `apt-get`（或 sudo 免密码）
- 若 `apt-get build-dep` 命令不可用，回退到 dpkg 查询方式
- 使用 `scripts/test-build-deps.sh` 辅助执行