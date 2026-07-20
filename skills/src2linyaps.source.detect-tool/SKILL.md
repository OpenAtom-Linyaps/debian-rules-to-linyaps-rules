---
name: src2linyaps.source.detect-tool
description: >
  扫描项目根目录，根据特征文件识别构建工具类型（cmake/meson/make/autotools）。
user-invocable: false
---

## 功能说明

扫描项目源码根目录，按优先级匹配特征文件，检测项目使用的构建工具类型。

## 触发场景

由主 Agent (`debian-rules-to-linyaps`) 在路径 B 工作流中编排调用，作为 fallback 路径的第一个子 Skill。

## 输入

| 名称 | 类型 | 描述 |
|------|------|------|
| project_path | string | 项目源码根目录路径 |

## 工作流程

1. 读取 `skills/config/build-tool-patterns.yaml` 获取特征文件标记
2. 扫描项目根目录，按优先级匹配：
   - `CMakeLists.txt` → cmake
   - `meson.build` → meson
   - `Makefile` 或 `GNUmakefile` → make
   - `configure` 或 `configure.ac` → autotools
3. 输出检测结果

## 输出

```yaml
tool_type: cmake
confidence: high
```

## 约束

- 优先级顺序：cmake → meson → make → autotools
- 如果多个特征文件同时存在，取优先级最高的结果
- 若无任何特征文件，输出 `tool_type: unknown`, `confidence: low`
- 使用 `scripts/detect-build-tool.sh` 辅助检测