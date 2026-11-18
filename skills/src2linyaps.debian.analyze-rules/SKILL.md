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
| agent_config_path | string | `agent-config.json` 的绝对路径，由主 agent 在 Step 1 解析后传入 |

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

## 约束

- 多个 binary 包的资源文件合并去重，不区分主包和 common-data
- `debian/rules` 中的 override 段需完整解析
- 如果 `debian/rules` 中无 dh 序列，尝试直接分析源码目录来推断构建工具
- 使用 `scripts/analyze-rules.py` 辅助解析
- `${PREFIX} 安装目录约束`：生成 `build_section` 时，所有安装目录参数（如 `-DCMAKE_INSTALL_PREFIX`、`--prefix`、`DESTDIR`）的值必须使用 `${PREFIX}` 环境变量而非硬编码路径（如 `/usr`、`/usr/local`），因为玲珑沙箱的安装根目录由运行时动态设定。脚本会同时输出 `prefix=${PREFIX}` 作为 Makefile 变量默认值。`build_args` 中从 debian/rules 提取的原始值（如 `/usr`）仅保留为参考信息