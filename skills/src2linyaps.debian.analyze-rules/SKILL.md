---
name: src2linyaps.debian.analyze-rules
description: >
  分析 debian 构建规则和资源文件，输出包含构建工具类型、编译参数及默认值、
  baseline 版本、源码包名、合并后资源列表的最终 YAML。
user-invocable: false
---

## 功能说明

分析 `debian/rules` 中的 dh 命令序列和构建参数，解析 `debian/changelog` 提取 baseline 版本，
关联扫描 `debian/*.install`、`debian/*.links`、`debian/*.docs`、`debian/*.manpages` 等资源文件，
合并多个 binary 包的资源文件列表，输出最终 YAML。

## 触发场景

由主 Agent (`debian-rules-to-linyaps`) 在路径 A 工作流中编排调用，在执行完 `src2linyaps.debian.analyze-control` 后执行。

## 输入

| 名称 | 类型 | 描述 |
|------|------|------|
| project_path | string | 项目源码根目录路径 |
| debian_path | string | `debian/` 目录路径 |
| control_info | dict | `analyze-control` 输出的结构化信息 |

## 工作流程

1. 分析 `debian/rules` 文件：
   - 识别 `dh` 命令序列（如 `dh_auto_configure`, `dh_auto_build` 等）
   - 提取 override 中的构建参数（如 `-DCMAKE_INSTALL_PREFIX=/usr`）
   - 根据 dh 序列推断构建工具类型（cmake/meson/make/autotools）
2. 解析 `debian/changelog` 提取 baseline 版本号（第一个条目）
3. 扫描 `debian/*.install` 文件 → 收集所有 binary 包的 install 资源
   - 处理多 destdir 的 `dh_install --destdir=debian/pkgA/` 模式
4. 扫描 `debian/*.links`、`debian/*.docs`、`debian/*.manpages` 等资源文件
5. 扫描 `debian/*.postinst`、`debian/*.prerm` 等 post 脚本，去重记录
6. 合并所有 binary 包的资源到单一输出
7. 组装最终 YAML

## 输出

```yaml
pkgName: kate
pkgDescription: "Kate is a text editor for KDE"
build_tool: cmake
build_tool_type: cmake
baseline: "4:25.04.3-2deepin1"
build_depends:
  - debhelper-compat (= 13)
  - dh-sequence-kf6
  - cmake (>= 3.16~)
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

## 约束

- 多个 binary 包的资源文件合并去重，不区分主包和 common-data
- `debian/rules` 中的 override 段需完整解析
- 如果 `debian/rules` 中无 dh 序列，尝试直接分析源码目录来推断构建工具
- 使用 `scripts/analyze-rules.py` 辅助解析