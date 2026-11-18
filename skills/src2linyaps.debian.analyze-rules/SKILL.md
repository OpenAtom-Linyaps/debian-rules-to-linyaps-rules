---
name: src2linyaps.debian.analyze-rules
description: >
  分析 debian 构建规则和资源文件，输出包含构建工具类型、编译参数及默认值、
  baseline 版本、源码包名、合并后资源列表、build_section 的最终 YAML。
user-invocable: false
---

## 功能说明

分析 `debian/rules` 中的 dh 命令序列和构建参数，解析 `debian/changelog` 提取 baseline 版本，
关联扫描 `debian/*.install`、`debian/*.links`、`debian/*.docs`、`debian/*.manpages` 等资源文件，
合并多个 binary 包的资源文件列表，基于构建工具类型和参数生成 `build_section`（可直接写入
`linglong.yaml` 的 `build:` 字段的 shell 脚本），输出最终 YAML。

## 触发场景

由主 Agent (`debian-rules-to-linyaps`) 在路径 A 工作流中编排调用，在执行完 `src2linyaps.debian.analyze-control` 后执行。
输出中的 `build_section` 字段将传递给 `src2linyaps.debian.build-res-generate` 用于组装最终的 `linglong.yaml`。

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
7. 基于构建工具类型和编译参数生成 `build_section` 构建脚本：
   - cmake: 生成 `cmake -B build-linglong ...` + `cmake --build ...` + `cmake --install ...`
   - meson: 生成 `meson setup build-linglong ...` + `ninja -C build-linglong` + `meson install ...`
   - make: 生成 `make -j$(nproc)` + `make install DESTDIR=${prefix}`
   - autotools: 生成 `./configure --prefix=${prefix} ...` + `make -j$(nproc)` + `make install`
   - 未知工具类型: 使用默认资源拷贝命令
8. **LLM 语义分析 `debian/rules`**（补充步骤，在脚本分析后执行）：
   a. 读取 `debian/rules` 完整内容
   b. 识别额外有意义的编译参数：
      - 关键 `--enable-*` / `--disable-*`（过滤平台无关项如 `--disable-d3d11va`、`--disable-wasapi`）
      - `--with-*` / `--without-*`
      - `CFLAGS` / `CXXFLAGS` / `LDFLAGS` 环境变量
      - 其他自定义参数（如 `--docdir`、`--with-binary-version`）
   c. 与 `build_args`（机械分析输出）去重
   d. 输出 `extra_args`（字符串，追加到 configure 命令末尾）
   e. 输出 `build_section`（完整自定义构建段，包含 LLM 分析的所有参数）
9. 组装最终 YAML（含 build_section、extra_args 字段）

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
build_section: |
  cmake -B build-linglong \
    -DCMAKE_INSTALL_PREFIX=${prefix} \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_TESTING=OFF
  cmake --build build-linglong -j$(nproc)
  cmake --install build-linglong
extra_args: "--enable-qt --enable-dbus --enable-udev"
```

### 补丁迁移输出（`migrate-patches.py`）

当 `debian/patches/series` 存在且含激活补丁时，`migrate-patches.py` 输出以下字段（独立于 `analyze()` 返回的 dict，由 A3.3 步骤编排调用）：

| 字段 | 类型 | 说明 |
------|------|------|
| `has_patches` | bool | 是否存在补丁 |
| `source_format` | str | 源码包格式（`3.0 (quilt)` / `3.0 (native)` / `''`） |
| `patches_applied` | list[str] | 成功应用的补丁列表（按 series 顺序） |
| `patches_failed` | list[dict] | 失败补丁列表，每项含 `name`/`error`/`rej_content` |
| `patches_disabled` | list[str] | 被 `#` 注释禁用的补丁列表 |
| `patch_commands` | str | 前置注入 `build_section` 的 shell 命令字符串（`export SRC_ROOT` + `cd ${SRC_ROOT}` + `patch -p1` 逐行） |
| `patches_dir` | str | 补丁文件输出目录 `<target_yaml_dir>/patches`（与 `linglong.yaml` 同级） |

## 约束

- 多个 binary 包的资源文件合并去重，不区分主包和 common-data
- `debian/rules` 中的 override 段需完整解析
- 如果 `debian/rules` 中无 dh 序列，尝试直接分析源码目录来推断构建工具
- 使用 `scripts/analyze-rules.py` 辅助解析
- **版本归一化**：输出的 `baseline` 为 Debian 原始版本（如 `30.2.3+dfsg-3deepin1`）。`generate-linglong-yaml.py` 会自动归一化为纯数字 4 段（`30.2.3.0`），**agent 无需手工改动 version 过校验**
- `${PREFIX} 安装目录约束`：生成 `build_section` 时所有安装目录参数使用 `${PREFIX}` 而非硬编码 `/usr`、`/usr/local`。`build_args` 中从 debian/rules 提取的原始值（如 `/usr`）仅保留为参考信息
- **补丁迁移为非阻断**：失败记 `patch_skipped` 警告，不阻断 Path A
- 补丁文件复制到 `patches/`（与 `linglong.yaml` 同级），映射到容器 `/project/linglong/patches/`
- `patch_commands` 前置于 `build_section` 的构建命令之前
- `patch_commands` 使用 `SRC_ROOT` 变量进入源码目录（`export SRC_ROOT=$(ls -d /project/linglong/sources/<source_name>/*); cd ${SRC_ROOT}`），与 linglong 源码进入约定一致，不硬编码 `cd /project/linglong/sources/<source_name>`
- 补丁以 shell 命令（`patch -p1`）形式注入 `build:` 段，非新增 schema 字段
- 使用显式逐文件 `patch -p1` 命令（非 glob），保留 series 顺序
- **宿主系统依赖**：`migrate-patches.py` 需宿主预装 `quilt`（`quilt push -a` 验证补丁应用）；容器内 `patch -p1` 执行依赖 `patch` 包，由 `generate-linglong-yaml.py` 检测 `build_section` 含 `patch -p1` 时自动追加到 `buildext.apt.build_depends`
- `scan-patches.py` 与 `migrate-patches.py` 为独立新脚本，不修改 `analyze-rules.py`

> 上下文效率：通用规则见 `src2linyaps.constraints` SKILL §7。本 skill 特有：输出含 `resources` 全量资源路径；调用方只读计数，不逐条 append。
