---
name: src2linyaps.source.analyze-args
description: >
  根据检测到的构建工具类型，读取对应构建配置文件，提取可修改编译参数及默认值。
user-invocable: false
---

## 功能说明

根据构建工具类型读取对应的构建配置文件，解析可修改的编译参数（如 prefix、DESTDIR、CMAKE_INSTALL_PREFIX 等），
输出构建工具类型和编译参数列表。

## 触发场景

由主 Agent (`debian-rules-to-linyaps`) 在路径 B 工作流中编排调用，在执行完 `src2linyaps.source.detect-tool` 后执行。

## 输入

| 名称 | 类型 | 描述 |
|------|------|------|
| project_path | string | 项目源码根目录路径 |
| tool_type | string | 检测到的构建工具类型 |

## 工作流程

1. 根据工具类型读取对应构建配置文件：
   - cmake: `CMakeLists.txt` 中的 `-DCMAKE_INSTALL_PREFIX=`, `-DCMAKE_BUILD_TYPE=` 等
   - meson: `meson_options.txt` 中的选项
   - make: `Makefile` 中的 `prefix`, `DESTDIR` 等变量
   - autotools: `configure` 中的 `--prefix=`, `--host=` 等
2. 参考 `skills/config/build-tool-patterns.yaml` 获取 common_args
3. 输出最终 YAML

## 输出

```yaml
build_tool: make
build_tool_type: make
build_args:
  - name: prefix
    default: /usr/local
  - name: DESTDIR
    default: ""
```

## 约束

- 配置文件可能非常大，仅扫描关键参数行
- 如果配置文件中自定义了常用参数值，优先使用自定义值而非默认值
- meson 通过 `meson_options.txt` 解析，cmake 从 `CMakeLists.txt` 解析，make 从 `Makefile` 解析
- 使用 `scripts/extract-build-args.py` 辅助解析