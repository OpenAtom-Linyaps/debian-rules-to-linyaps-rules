# runtimeDepends 解析方案

## 概述

从 `debian/control` 的 `Build-Depends` 字段出发，通过查询系统 apt 仓库，解析出应用运行时所依赖的共享库和应用组件列表（`runtimeDepends`）。这些包名最终写入玲珑 YAML 的 `depends` 字段。

## 架构

```
debian/control
      │
      ▼
┌─────────────────────┐
│   init-control.py   │  ← wrapper 入口
│  (单步调用)          │
└─────┬─────────┬─────┘
      │         │
      ▼         ▼
┌──────────┐  ┌──────────────────────┐
│parse-    │  │resolve-runtime-      │
│control.py│  │deps.py               │
│          │  │                      │
│解析      │  │apt-cache depends 查询 │
│Build-    │  │黑名单过滤             │
│Depends   │  │去重排序               │
└──────────┘  └──────────────────────┘
      │               │
      └───────┬───────┘
              ▼
      ┌──────────────┐
      │  完整 YAML    │
      │ buildDepends │
      │ runtimeDepends│
      │ binaryPackages│
      └──────────────┘
```

## 核心原理

### 1. 提取 Build-Depends

`parse-control.py` 解析 `debian/control` 中的：

- `Build-Depends:`
- `Build-Depends-Arch:`
- `Build-Depends-Indep:`

三者做并集去重。处理 `|`（或）语法时取第一个选项。

### 2. 裸包名提取

`resolve-runtime-deps.py` 中的 `strip_version()` 函数将带版本约束的依赖字符串转为裸包名：

```python
# 输入 → 输出
"cmake (>= 3.16~)"     → "cmake"
"xauth <!nocheck>"     → "xauth"
"libc6:amd64"          → "libc6"
"libcairo2-dev (>= 1.10)" → "libcairo2-dev"
```

正则规则：

| 规则 | 正则 | 示例 |
|------|------|------|
| 移除版本约束 | `r'\s*\([^)]*\)'` | `(>= 1.10)` → 空 |
| 移除构建 profile | `r'\s*<![^>]+>'` | `<!nocheck>` → 空 |
| 移除架构限定 | `r':\w+$'` | `:amd64` → 空 |

### 3. apt-cache depends 查询

对每个裸包名，执行系统命令：

```bash
LC_ALL=C apt-cache depends <pkg>
```

输出示例（`libcairo2-dev`）：

```
libcairo2-dev
  依赖: libcairo2
  依赖: libfontconfig-dev
  依赖: <libcairo2-script-interpreter>    ← 虚拟包，跳过
  推荐: libcairo2-doc
```

解析规则：

| apt-cache 行模式 | 含义 | 是否提取 |
|---|---|---|
| `libcairo2-dev` | 主包名（无缩进） | ❌ |
| `  Depends: libcairo2` | 依赖包 | ✅ |
| `  Recommends: libcairo2-doc` | 推荐包 | 第一层 ✅，递归层 ❌ |
| `  Depends: <虚拟包>` | 虚拟包 | ❌ |
| `    libcairo2` | 四级缩进（替代包） | ❌ |

`include_recommends` 参数控制是否提取 Recommends：
- 第一层（Build-Depends 的直接依赖）：`include_recommends=True`，提取 Depends + Recommends
- 递归层（第 2~3 层）：`include_recommends=False`，仅提取 Depends

### 3.1 递归解析策略

从 Build-Depends 出发，最多递归 3 层：

```
第 1 层: Build-Depends 包 ──Depends+Recommends──→ 运行时依赖 A、B、C...
第 2 层: A ──Depends──→ D、E...
第 3 层: D ──Depends──→ F、G...
```

递归终止条件：
- 达到最大深度（`MAX_RECURSE_DEPTH = 3`）
- 包已在 `seen` 缓存中（避免重复查询和循环依赖）

### 4. 黑名单过滤

从结果中剔除不应当写入玲珑 `depends` 的包，通过 `runtime-depends-blacklist.json` 配置。

黑名单分类：

| 类别 | 示例 |
|------|------|
| GCC 工具链 | `gcc`, `g++`, `cpp`, `gcc-14-base` |
| Binutils | `binutils`, `libbinutils`, `libctf0` |
| 构建工具 | `make`, `cmake`, `meson`, `ninja-build` |
| pkg-config | `pkg-config`, `pkgconf` |
| autotools | `autoconf`, `automake`, `libtool`, `m4` |
| 代码生成 | `bison`, `flex`, `gawk` |
| LLVM/Clang | `llvm`, `clang`, `lld`, `compiler-rt` |
| 静态语言 | `rustc`, `cargo`, `golang`, `go` |
| Mesa 驱动 | `mesa`, `libgl1-mesa-dri`, `libegl-mesa0` |

### 5. 缓存、去重与排序

- `seen` 集合：记录已通过 `apt-cache depends` 查询过的包，避免重复查询和循环依赖
- `runtime_deps_set` 集合：记录已加入结果列表的包，防止重复添加
- 已出现在 `buildDepends` 中的包不加入 `runtimeDepends`（由主循环控制，不查询 Build-Depends 包自身的运行时依赖）
- 最终按字母序排序输出

## 完整数据流示例

以 thunderbird 的 `debian/control` 为例（部分）：

```
Build-Depends:
 libasound2-dev [linux-any],
 libcairo2-dev (>= 1.10.2-1.1~),
 libgtk-3-dev (>= 3.4),
 libpulse-dev,
 libnss3-dev (>= 2:3.97~),
 zlib1g-dev,
 ...
```

解析过程：

| Step | 操作 | 结果 |
|------|------|------|
| 1. 解析 control | → `buildDepends` | `["libasound2-dev", "libcairo2-dev (>= 1.10...)", ...]` |
| 2. strip_version | → 裸包名 | `["libasound2-dev", "libcairo2-dev", "libgtk-3-dev", ...]` |
| 3. apt-cache depends（第 1 层，含 Recommends） | → 直接运行时依赖 | `libasound2`、`libcairo2`、`libgtk-3-0`、`libfontconfig-dev`... |
| 4. 过滤 -dev/-dbgsym/-dbg/-doc | → 排除 `libfontconfig-dev` | `libasound2`、`libcairo2`、`libgtk-3-0`... |
| 5. 递归解析（第 2 层，仅 Depends） | → 间接依赖 | `libasound2-data`、`libfontconfig1`（来自 `libcairo2`）、`libglib2.0-0`（来自 `libgtk-3-0`）... |
| 6. 递归解析（第 3 层，仅 Depends） | → 更深层依赖 | `libpcre2-8-0`（来自 `libglib2.0-0`）... |
| 7. 黑名单过滤 | 编译器/Mesa 剔除 | 无命中（上述均为共享库） |
| 8. 去重排序 | → 最终列表 | `["libasound2", "libasound2-data", "libcairo2", "libfontconfig1", "libglib2.0-0", "libgtk-3-0", "libpcre2-8-0", "libpulse0", ...]` |

## 关键设计决策

### 为什么用 apt-cache 而不是 apt-get build-dep?

- `apt-cache depends` 是**只读查询**，不修改系统状态
- 可以精确控制只提取 `Depends` 和 `Recommends`，排除 `Suggests`、`Enhances`、`Breaks` 等无关字段
- 输出格式稳定，易于解析

### 为什么排除 -dev 包？

`libcairo2-dev` 的运行时依赖包括 `libfontconfig-dev`。但 `libfontconfig-dev` 是构建工具链的一部分，不应出现在玲珑的运行时 `depends` 中。过滤规则：

- `-dev` 包在 `buildDepends` 中 → 是构建时依赖
- `-dev` 包的 `apt-cache depends` 输出中仍可能出现其他 `-dev` 包 → 被 `is_runtime_package()` 过滤
- `-dev` 包依赖的非 `-dev` 共享库（如 `libcairo2`）→ 加入 `runtimeDepends`

除 `-dev` 外，还过滤以下后缀：

| 后缀 | 类别 | 示例 |
|------|------|------|
| `-dev` | 开发头文件/静态库 | `libcairo2-dev` |
| `-dbgsym` | 调试符号包 | `libc6-dbgsym` |
| `-dbg` | 调试符号包（旧式） | `libfoo-dbg` |
| `-doc` | 文档包 | `libcairo2-doc` |

### 为什么需要黑名单？

- GCC/LLVM/Mesa 等包在某些 apt 配置下会被标记为 `Depends`，但它们不是应用运行时的必要组件
- 硬编码黑名单比运行时检测更可靠、更可预测

## 调用方式

### 单步调用（推荐）

```bash
python3 init-control.py <control_file> \
  --blacklist runtime-depends-blacklist.json
```

输出示例：

```yaml
pkgName: thunderbird
pkgDescription: "Mail client"
buildDepends:
  - libcairo2-dev (>= 1.10.2-1.1~)
  - libgtk-3-dev (>= 3.4)
  - ...
buildDependsAlternatives:
  - - libjack-jackd2-dev
    - libjack-dev
binaryPackages:
  - thunderbird
  - thunderbird-l10n-all
runtimeDepends:
  - libasound2
  - libcairo2
  - libgtk-3-0
  - libnss3
  - libpulse0
  - zlib1g
```

### 分步调用（调试用）

```bash
python3 parse-control.py <control_file> > control.yaml
python3 resolve-runtime-deps.py control.yaml \
  --blacklist runtime-depends-blacklist.json
```

## 失败处理

| 场景 | 行为 |
|------|------|
| apt-cache 命令不存在 | 输出 WARNING，`runtimeDepends` 为空列表 |
| apt-cache 超时 | 输出 WARNING，跳过该包（递归中某层超时不阻断整体流程） |
| 查询包不存在 | 输出 WARNING，跳过该包 |
| blacklist JSON 不存在 | 输出 WARNING，不过滤 |
| 递归深度达到上限 | 自动终止递归，已有结果正常输出 |

所有失败不影响 `buildDepends`、`binaryPackages` 等其他字段的产出，保证主流程不中断。
