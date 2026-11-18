# 自定义源 deb 解压方案 — `src2linyaps.debian.build-res-generate` + `src2linyaps.debug` 可发现性

## 背景

为 `src2linyaps.debian.build-res-generate` 技能新增解压自定义来源 deb 的能力，并确保 `src2linyaps.debug` 在诊断到运行库丢失时可调用该能力。用户在打包源码项目时，部分构建/运行依赖无法通过 apt 仓库获取（私有源、特定版本、补丁版库），需通过 deb URL 下载并在构建阶段解压到 `${PREFIX}`，使主构建命令能直接链接使用这些库/工具。当 `src2linyaps.debug` 诊断到运行库丢失（阶段二 `buildext 依赖缺失/多余` 或阶段四运行验证失败）时，debug skill 需能发现并调用 `--custom-deb-urls` 重新生成 `linglong.yaml` 以补齐缺失的运行库。

参考技能 `bin2linyaps.external-missing-deps-fetch` 已实现等价能力，但运行在**二进制打包上下文**（`pak_linyaps.sh` 构建后针对 `binary_dir` 调用 `download_missing_deps.sh`）。本方案运行在**源码打包上下文**（`ll-builder` 容器内 `build:` 段构建前/中执行），两者关键差异：

| 维度 | 引用技能（二进制打包） | 本方案（源码打包） |
|------|----------------------|-------------------|
| 执行时机 | 构建完成后 | 构建前/中（`build:` 段内） |
| 执行者 | `pak_linyaps.sh`（宿主脚本） | `ll-builder` 容器内 shell |
| 解压目标 | `binary_dir`（等价容器虚拟 /usr） | `${PREFIX}`（容器安装路径） |
| 配置入口 | `missing_deps_urls.conf`（fetch 脚本生成） | `custom_debs_urls.conf`（用户/agent 提供） |
| 脚本引入容器 | `pak_linyaps.sh` 直接调用宿主脚本 | `build:` 段内联调用（脚本随 `linglong.yaml` 同级目录引入容器） |
| URL 来源 | `apt-get download --print-uris` 自动获取 | 用户/上层 agent 显式提供 |

## 核心约束

1. **不生成 `sources:` 段**（SKILL.md L103）：`validate-linglong-yaml.py` L332-334 硬编码 `NO_SOURCES` 检查拒绝 `sources:` 字段。deb 提取必须通过 `build:` 段内联命令实现。
2. **`${PREFIX}` 安装目录约束**（SKILL.md L110，约束 §1）：deb 内容最终安装到 `${PREFIX}`，`usr` 子目录平铺（`usr/bin`→`${PREFIX}/bin`）。
3. **静态脚本+配置文件**（用户决策）：仿照引用 skill 生成 `download_custom_debs.sh` + `custom_debs_urls.conf`，`build:` 段调用该脚本。
4. **脚本在容器 `/project` 内执行**（用户决策）：`build:` 段在 `ll-builder` 容器内作为 shell 脚本执行，脚本需放置在容器可访问路径。

## 核心矛盾与解决方案

**矛盾**：`build:` 段在 `ll-builder` 容器内执行，容器内无法直接访问宿主机上的静态脚本文件。约束 1 禁止 `sources:` 段，无法通过 linglong 原生机制引入脚本文件。

**解决方案（参考补丁文件引入模式）**：`migrate-patches.py` 将补丁文件复制到 `patches/`（与 `linglong.yaml` 同级），映射到容器 `/project/linglong/patches/`，`build:` 段用 `patch -p1` 命令引用。本方案复用此模式：

1. 生成器将 `download_custom_debs.sh` 复制到输出目录（`linglong.yaml` 同级），映射到容器 `/project/linglong/`（与 `linglong.yaml` 同级目录在容器内挂载到 `/project/linglong/`）。
2. `build:` 段注入调用命令：`bash /project/linglong/download_custom_debs.sh "${PREFIX}"`，在 clang export 之后、主构建命令之前执行（deb 可能提供构建时依赖）。
3. `custom_debs_urls.conf` 同样复制到输出目录，脚本通过相对路径 `${SCRIPT_DIR}/custom_debs_urls.conf` 加载（`SCRIPT_DIR` 由 `BASH_SOURCE` 推导）。

## 用户决策

1. **deb URL 输入方式**：新增 `--custom-deb-urls` CLI 参数，接受配置文件路径（含 URL 列表）。
2. **注入机制**：静态脚本+配置文件（`download_custom_debs.sh` + `custom_debs_urls.conf`）。
3. **解压目标**：`${PREFIX}`（deb 内容最终安装到 `${PREFIX}`，`usr` 子目录平铺）。
4. **执行位置**：脚本在容器 `/project` 内完成解压，最终安装到 `${PREFIX}`。

## 方案步骤（按执行顺序）

### 步骤 1：创建静态脚本 `download_custom_debs.sh`（新文件）

**目标文件**：`skills/src2linyaps.debian.build-res-generate/scripts/download_custom_debs.sh`（新建）

**职责**：解析 `custom_debs_urls.conf` 中的 URL 列表，下载 deb 并解压到 `${PREFIX}`。基于引用 `download_missing_deps.sh`（113 行）改造，核心差异：
- 目标参数：`${1:-${PREFIX}}` 而非 `binary_dir`（用户传入 `${PREFIX}` 作为解压目标）
- 数组名：`CUSTOM_DEB_URLS` 而非 `MISSING_DEPS_URLS`
- 配置文件名：`custom_debs_urls.conf` 而非 `missing_deps_urls.conf`
- `IMPORTANT_DIRS` 白名单 + `usr` 平铺逻辑完全复用（权威，引用脚本 L41/L80-105）

**脚本结构**（基于引用 `download_missing_deps.sh` L1-113，逐行改造）：

```bash
#!/bin/bash
# src2linyaps.debian.build-res-generate
# 静态下载解压脚本，由 build: 段在 ll-builder 容器内调用
# 解析脚本同级目录下的 custom_debs_urls.conf，下载并解压 deb 到 ${PREFIX}
# 不依赖外部 fetch 脚本，支持用户手动创建 conf
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/custom_debs_urls.conf"
# 解压目标：第一个参数（build: 段传入 ${PREFIX}），回退 ${PREFIX} 环境变量
TARGET_DIR="${1:-${PREFIX:-/opt/apps/unknown}}"

if [ ! -f "$CONF_FILE" ]; then
  echo "INFO: 未找到 custom_debs_urls.conf，无需下载" >&2
  exit 0
fi

# source 前临时关闭 set -u
set +u
source "$CONF_FILE"
set -u

if [ ${#CUSTOM_DEB_URLS[@]} -eq 0 ]; then
  echo "INFO: custom_debs_urls.conf 中无 URL，无需下载" >&2
  exit 0
fi

url_decode() {
  python3 -c 'import urllib.parse,sys;print(urllib.parse.unquote(sys.argv[1]))' "$1"
}

DEB_CACHE="/tmp/lingyaps-custom-debs"
IMPORTANT_DIRS=(usr bin sbin lib lib32 lib64 libexec include share local)

mkdir -p "$TARGET_DIR" "$DEB_CACHE"

FAIL_COUNT=0
for url in "${CUSTOM_DEB_URLS[@]}"; do
  deb_file="$DEB_CACHE/$(url_decode "$(basename "$url")")"
  echo "下载: $url"
  if ! wget -q --tries=3 "$url" -O "$deb_file"; then
    echo "WARN: 下载失败: $url" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi
  if ! dpkg-deb -I "$deb_file" >/dev/null 2>&1; then
    echo "WARN: 下载内容非有效 deb（可能为错误页）: $url" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
    rm -f "$deb_file"
    continue
  fi
  echo "解压: $deb_file"
  EXTRACT_DIR=$(mktemp -d)
  if command -v dpkg >/dev/null 2>&1; then
    dpkg -x "$deb_file" "$EXTRACT_DIR"
  else
    dpkg-deb -x "$deb_file" "$EXTRACT_DIR"
  fi
  if [ $? -ne 0 ]; then
    echo "WARN: 解压失败: $deb_file" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
    rm -f "$deb_file"
    rm -rf "$EXTRACT_DIR"
    continue
  fi
  for entry in "$EXTRACT_DIR"/*; do
    [ -e "$entry" ] || continue
    name="$(basename "$entry")"
    important=0
    for d in "${IMPORTANT_DIRS[@]}"; do
      if [ "$d" = "$name" ]; then
        important=1
        break
      fi
    done
    [ "$important" -eq 1 ] || continue
    if [ "$name" = "usr" ] && [ -d "$entry" ]; then
      for sub in "$entry"/*; do
        [ -e "$sub" ] || continue
        if ! cp -rf "$sub" "$TARGET_DIR/"; then
          echo "WARN: 复制失败: $sub -> $TARGET_DIR/" >&2
          FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
      done
    else
      if ! cp -rf "$entry" "$TARGET_DIR/"; then
        echo "WARN: 复制失败: $entry -> $TARGET_DIR/" >&2
        FAIL_COUNT=$((FAIL_COUNT + 1))
      fi
    fi
  done
  rm -rf "$EXTRACT_DIR"
  rm -f "$deb_file"
done

TOTAL=${#CUSTOM_DEB_URLS[@]}
SUCCESS=$((TOTAL - FAIL_COUNT))
echo "完成: 成功 $SUCCESS/$TOTAL 个自定义 deb 已解压到 $TARGET_DIR"
[ "$FAIL_COUNT" -eq 0 ] || echo "WARN: $FAIL_COUNT 个包处理失败" >&2
```

**与引用脚本的关键差异**（逐行）：
- L4-5 注释：改为本 skill 名称 + 容器内执行说明
- L9-10 `PROJECT_ROOT`→`SCRIPT_DIR`，`CONF_FILE` 改为 `${SCRIPT_DIR}/custom_debs_urls.conf`（脚本与 conf 同级，均在 `linglong.yaml` 同级目录，映射到容器 `/project/linglong/`）
- L11 `BINARY_DIR`→`TARGET_DIR`，默认值 `${1:-${PREFIX}}`（build 段传入 `${PREFIX}`）
- L24 `MISSING_DEPS_URLS`→`CUSTOM_DEB_URLS`
- L34 `DEB_CACHE` 改为 `/tmp/lingyaps-custom-debs`（避免与引用技能缓存冲突）
- L41 `IMPORTANT_DIRS` 完全复用（权威白名单）
- L46-107 循环体完全复用（下载→验证→解压→白名单复制→usr 平铺→清理）
- L110-112 摘要输出中 `依赖包`→`自定义 deb`、`$BINARY_DIR`→`$TARGET_DIR`

### 步骤 2：创建配置文件格式规范文档（新文件）

**目标文件**：`skills/src2linyaps.debian.build-res-generate/reference/custom_debs_urls_conf_format.md`（新建）

**内容**（基于引用 `missing_deps_urls_conf_format.md` 改造）：

```markdown
# custom_debs_urls.conf 格式规范

## 格式示例

\`\`\`bash
# 由用户提供或上层 agent 生成，传入 --custom-deb-urls
# 位于 linglong.yaml 同级目录，映射到容器 /project/linglong/
# 可人工编辑：增删改 URL 行后重新构建即可
CUSTOM_DEB_URLS=(
  "https://example.com/repo/libcustom1_1.0.0_amd64.deb"
  "https://example.com/repo/libcustom2_2.1.3%2bpatch1_amd64.deb"
)
\`\`\`

## 格式规范表

| 部分 | 说明 |
|------|------|
| 3 行注释头 | 固定内容，标识用途、位置、可编辑提示 |
| `CUSTOM_DEB_URLS=(...)` | bash 数组，每行一个 URL（带引号） |
| URL 百分号编码 | `+` 编码为 `%2b`，空格编码为 `%20` 等（URL 标准编码） |

## 加载机制

`download_custom_debs.sh` 通过 `source "${SCRIPT_DIR}/custom_debs_urls.conf"` 加载 `CUSTOM_DEB_URLS` 数组。

加载前临时关闭 `set -u`，避免 conf 未定义数组时中断。

## 人工编辑规则

- 增删改 URL 行后重新构建即可（`ll-builder build` 会重新执行 `build:` 段）。
- 保持 3 行注释头 + `CUSTOM_DEB_URLS=(...)` 数组语法不变。
- 每个 URL 用双引号包裹，单独一行。
```

### 步骤 3：修改 `generate-linglong-yaml.py` — 新增 `--custom-deb-urls` 参数 + build 段注入 + 脚本复制

**目标文件**：`skills/src2linyaps.debian.build-res-generate/scripts/generate-linglong-yaml.py`（修改，当前 582 行）

**改动点 3.1：新增常量**（L36-41 区域，现有 `SOURCE_BUILD_TOOLS`/`CLANG_BUILD_DEPS`/`PATCH_BUILD_DEPS` 之后）

```python
# 自定义 deb 解压脚本名（随 linglong.yaml 同级复制到输出目录，映射到容器 /project/linglong/）
CUSTOM_DEB_SCRIPT = "download_custom_debs.sh"
CUSTOM_DEB_CONF = "custom_debs_urls.conf"
# 容器内脚本路径（linglong.yaml 同级目录在容器内挂载到 /project/linglong/）
CUSTOM_DEB_SCRIPT_CONTAINER = "/project/linglong/download_custom_debs.sh"
```

**改动点 3.2：新增 `--custom-deb-urls` CLI 参数**（L488-492 区域，`--no-clang` 之后）

```python
    parser.add_argument(
        "--custom-deb-urls",
        default="",
        help="自定义 deb URL 配置文件路径（custom_debs_urls.conf），"
        "build 段会注入调用 download_custom_debs.sh 的命令",
    )
```

**改动点 3.3：`main()` 中处理 `--custom-deb-urls`**（L493 `args = parser.parse_args()` 之后，L495 `control_info = read_yaml(args.control_info)` 之前）

```python
    custom_deb_urls_file = args.custom_deb_urls
    has_custom_debs = bool(custom_deb_urls_file) and os.path.isfile(custom_deb_urls_file)
```

**改动点 3.4：`build_yaml()` 新增 `custom_debs` 参数**（L265-276 函数签名）

在 `use_clang=False` 之后、`reference=None` 之前新增参数：

```python
def build_yaml(
    data,
    build_section,
    version,
    architecture,
    base,
    runtime,
    command,
    with_deps,
    use_clang=False,
    custom_debs=False,
    reference=None,
):
```

**改动点 3.5：`build_yaml()` 中注入 deb 提取命令**（L307 `with_deps = True` 之后、L308 `touch` 之前）

在 patch 依赖处理块之后、`touch`/`chmod` 追加之前，注入 deb 提取命令。注入位置选择：在主构建命令之后、`touch`/`chmod` 之前——理由：deb 提取的库/工具在主构建命令执行时需已就位，而 `touch`/`chmod` 是最终的收尾操作，deb 内容需在 `chmod -R 755` 之前落入 `${PREFIX}`。

```python
    # 自定义 deb 解压（容器内 /project/linglong/download_custom_debs.sh）
    # 在 touch/chmod 之前执行：deb 内容需在 chmod -R 755 之前落入 ${PREFIX}
    if custom_debs:
        build_section += f'bash {CUSTOM_DEB_SCRIPT_CONTAINER} "${{PREFIX}}"\n'
```

**改动点 3.6：`main()` 中传递 `custom_debs` 到 `build_yaml()`**（L550-561 调用处）

```python
    result = build_yaml(
        control_info,
        build_section,
        version,
        architecture,
        base,
        runtime,
        command,
        with_deps,
        use_clang,
        custom_debs=has_custom_debs,
        reference=reference,
    )
```

**改动点 3.7：`main()` 中复制脚本和配置文件到输出目录**（L572 `os.makedirs` 之后、L573 写文件之前）

```python
    # 复制自定义 deb 脚本和配置文件到输出目录（linglong.yaml 同级）
    # 映射到容器 /project/linglong/，build 段通过绝对路径调用
    if has_custom_debs:
        import shutil
        script_dir = os.path.dirname(os.path.abspath(__file__))
        src_script = os.path.join(script_dir, CUSTOM_DEB_SCRIPT)
        out_dir = os.path.dirname(args.output) or "."
        dst_script = os.path.join(out_dir, CUSTOM_DEB_SCRIPT)
        dst_conf = os.path.join(out_dir, CUSTOM_DEB_CONF)
        shutil.copy2(src_script, dst_script)
        shutil.copy2(custom_deb_urls_file, dst_conf)
        print(f"custom deb script copied: {dst_script}")
        print(f"custom deb urls conf copied: {dst_conf}")
```

### 步骤 4：验证 `validate-linglong-yaml.py` 无需修改

**目标文件**：`skills/src2linyaps.debian.build-res-generate/scripts/validate-linglong-yaml.py`（不修改，验证兼容性）

注入的 build 段命令为 `bash /project/linglong/download_custom_debs.sh "${PREFIX}"`。验证器各项检查的兼容性分析：

| 检查项 | 行号 | 检查内容 | 注入命令是否触发 | 原因 |
|--------|------|----------|------------------|------|
| 硬编码前缀检测 | L257-293 | `=<hardcoded_path>` 模式（如 `-DCMAKE_INSTALL_PREFIX=/`） | 否 | 注入命令无 `=` 后跟路径的模式 |
| 必需命令检查 | L304-310 | `tools.<tool>.commands` 中的 patterns | 否 | 注入命令不是构建工具命令，不影响必需命令匹配 |
| 禁用参数检查 | L304-310 | `tools.<tool>.forbidden` 中的 patterns | 否 | forbidden 仅含 `DESTDIR=`，注入命令无此模式 |
| 安装目录映射 | L311-330 | `install_dir_mapping` 中的 `pattern` 变量 | 否 | 注入命令无 `-DCMAKE_INSTALL_*` 或 `--bindir=` 等变量 |
| NO_SOURCES 检查 | L332-334 | `sources` 顶层字段 | 否 | 本方案不生成 `sources:` 段 |

**结论**：验证器无需修改。注入命令通过所有现有检查。

### 步骤 5：更新 `SKILL.md` — 新增 `--custom-deb-urls` 参数说明

**目标文件**：`skills/src2linyaps.debian.build-res-generate/SKILL.md`（修改，当前 143 行）

**改动点 5.1：约束段新增条目**（L119 patch 构建依赖条目之后）

```markdown
- `自定义 deb 解压`：用户提供 `--custom-deb-urls <conf_file>` 时（`custom_debs_urls.conf`，
  含 `CUSTOM_DEB_URLS=(...)` bash 数组），build 段在 `touch`/`chmod` 之前注入
  `bash /project/linglong/download_custom_debs.sh "${PREFIX}"`。
  脚本和配置文件复制到 `linglong.yaml` 同级目录（映射到容器 `/project/linglong/`），
  下载 deb 并解压到 `${PREFIX}`（`usr` 子目录平铺）。
  容器内需预装 `wget`、`dpkg`/`dpkg-deb`、`python3`。deb 下载失败为非阻断（`FAIL_COUNT++`，继续）。
```

**改动点 5.2：目录约定新增条目**（如 SKILL.md 有目录约定段；若无，在约束段后新增）

```markdown
## 自定义 deb 解压产物

| 文件 | 路径 | 说明 |
|------|------|------|
| `download_custom_debs.sh` | `scripts/download_custom_debs.sh`（复制到输出目录） | 静态下载解压脚本，容器内由 build 段调用 |
| `custom_debs_urls.conf` | 用户提供的配置文件（复制到输出目录） | URL 列表，`CUSTOM_DEB_URLS=(...)` bash 数组 |
```

### 步骤 5.5：更新 `src2linyaps.debug/SKILL.md` — 诊断「运行库丢失」并通知 agent 调用 `build-res-generate`

**目标文件**：`skills/src2linyaps.debug/SKILL.md`（修改，当前 416 行）

**背景**：debug skill 是 agent 执行指南，阶段三修复表（L93-100）按诊断问题路由到对应内部 skill，由 agent 读取该 skill 的 SKILL.md 后执行。当前修复表无「运行库丢失」分支：诊断到运行库缺失时，仅通过 `analyze-control` 修正 `runtimeDepends`（apt 仓库内补齐），无法处理 apt 仓库不存在的运行库。需新增分支：当运行库缺失且不在 apt 仓库时，debug skill 通知 agent 调用 `src2linyaps.debian.build-res-generate`（本技能），由该技能的 SKILL.md 指导 agent 使用 `--custom-deb-urls` 重新生成 `linglong.yaml`。debug skill 自身不直接执行 `--custom-deb-urls`，不直接调用 `download_custom_debs.sh`。

**改动点 5.5.1：阶段二诊断清单新增问题类型**（L86 `buildext 依赖缺失/多余` 之后）

当前 L86：
```markdown
   - **buildext 依赖缺失/多余**
```
新增（L86 之后）：
```markdown
   - **运行库丢失（非 apt 可补齐）**：`<workdir>/files/lib` 下 `.so` 文件 `ldd` 检测有 `not found`，且缺失库不在 apt 仓库（`apt-cache show <libname>` 无结果）→ 需通知 agent 调用 `build-res-generate` 通过自定义 deb URL 下载补齐
```

**改动点 5.5.2：阶段三修复表新增分支**（L98 `buildext 依赖问题` 行之后）

当前 L98：
```markdown
| buildext 依赖问题 | `src2linyaps.debian.analyze-control` + `src2linyaps.debian.test-deps` | 修正 buildDepends/runtimeDepends |
```
新增（L98 之后）：
```markdown
| 运行库丢失（非 apt 可补齐） | `src2linyaps.debian.build-res-generate` | 通知 agent 调用本技能，按其 SKILL.md 使用 `--custom-deb-urls` 重新生成 `linglong.yaml`，注入 deb 提取命令补齐缺失运行库 |
```

注：debug skill 的「重新生成 linglong.yaml」代码块（L102-114）**不新增 `--custom-deb-urls`**。该参数由 `build-res-generate` SKILL.md（步骤 5）文档化，agent 被路由到 `build-res-generate` 后读取该 SKILL.md 获取 `--custom-deb-urls` 用法。debug skill 仅负责诊断 + 路由通知。

**改动点 5.5.3：阶段四运行验证失败时回退诊断**（L292-344 运行验证段，在失败处理逻辑中新增）

当 `ll-builder run` 退出码非 0/124（`run_verify="failed"`），且错误信息含 `error while loading shared libraries` 或 `cannot open shared object file` 时，回退到阶段二重新诊断「运行库丢失（非 apt 可补齐）」，经阶段三路由到 `build-res-generate` 修复后重新构建验证。

在阶段四运行验证失败处理处新增回退说明：
```markdown
- 运行验证失败且错误含 `error while loading shared libraries` / `cannot open shared object file` → 回退阶段二，按「运行库丢失（非 apt 可补齐）」重新诊断，阶段三路由到 `build-res-generate`（`--custom-deb-urls`）修复后重新构建验证
```

**改动点 5.5.4：内部 skills 清单表更新**（L58 `src2linyaps.debian.build-res-generate` 行）

当前 L58：
```markdown
| `src2linyaps.debian.build-res-generate` | `skills/src2linyaps.debian.build-res-generate/` | 生成/重新生成 `linglong.yaml` + 校验（`generate-linglong-yaml.py` / `validate-linglong-yaml.py`） |
```
修改为（用途列追加运行库丢失路由场景）：
```markdown
| `src2linyaps.debian.build-res-generate` | `skills/src2linyaps.debian.build-res-generate/` | 生成/重新生成 `linglong.yaml` + 校验；运行库丢失（非 apt 可补齐）时 agent 按其 SKILL.md 用 `--custom-deb-urls` 注入 deb 提取（`generate-linglong-yaml.py` / `validate-linglong-yaml.py` / `download_custom_debs.sh`） |
```

注：debug skill 内部资源清单（L31-36）**不新增** `download_custom_debs.sh` 路径。该脚本由 `build-res-generate` SKILL.md（步骤 5）文档化，debug skill 不直接调用它，仅路由到 `build-res-generate`。
### 步骤 6：更新 `agents/debian-rules-to-linyaps.agent.md` — 主 agent 调用新增参数

**目标文件**：`agents/debian-rules-to-linyaps.agent.md`（修改，当前 175 行）

**改动点 6.1：Step A4 调用命令新增 `--custom-deb-urls`**（L108-118）

在 `--output output/linglong.yaml` 之前新增可选参数行：

```bash
python3 skills/src2linyaps.debian.build-res-generate/scripts/generate-linglong-yaml.py \
  --control-info <control_info.yaml> \
  --build-section "<build_section>" \
  --build-tool <tool_type> \
  --build-args '<build_args_json>' \
  --extra-args '<extra_args_string>' \
  --package-version <baseline> \
  --defaults skills/config/linglong-defaults.json \
  --custom-deb-urls <custom_debs_urls.conf> \
  --output output/linglong.yaml
```

新增说明（L118 代码块之后）：

```markdown
- **`--custom-deb-urls`**（可选）：当用户提供自定义 deb URL 配置文件时传入。
  配置文件格式见 `reference/custom_debs_urls_conf_format.md`。
  传入后 build 段注入 `bash /project/linglong/download_custom_debs.sh "${PREFIX}"`，
  脚本和配置文件复制到输出目录。未提供时不注入。
```

## 验证方案

### 单元验证

1. **生成器测试**：准备测试用 `control_info.yaml` + `custom_debs_urls.conf`，运行：
   ```bash
   python3 skills/src2linyaps.debian.build-res-generate/scripts/generate-linglong-yaml.py \
     --control-info test_control.yaml \
     --build-section "cmake -B build -DCMAKE_INSTALL_PREFIX=\${PREFIX}\nmake -j\$(nproc)\nmake install" \
     --build-tool cmake \
     --defaults skills/config/linglong-defaults.json \
     --custom-deb-urls test_custom_debs.conf \
     --output /tmp/test_linglong.yaml
   ```
   验证：`/tmp/test_linglong.yaml` 的 `build:` 段含 `bash /project/linglong/download_custom_debs.sh "${PREFIX}"`，且在 `touch`/`chmod` 之前；`download_custom_debs.sh` 和 `custom_debs_urls.conf` 已复制到 `/tmp/`。

2. **验证器测试**：对生成的 `/tmp/test_linglong.yaml` 运行：
   ```bash
   python3 skills/src2linyaps.debian.build-res-generate/scripts/validate-linglong-yaml.py \
     /tmp/test_linglong.yaml --build-tool cmake \
     --schema skills/config/linglong-schema.yaml
   ```
   验证：退出码 0，无 error。

3. **回归测试**：不传 `--custom-deb-urls` 时，生成结果与改动前一致（build 段无 deb 提取命令，无文件复制）。

### 端到端验证（VLC 测试项目）

**测试项目**：`examples/vlc-with-patches/CI_ll_org.videolan.www.vlc/`
- Package id：`org.videolan.www.vlc`，version `3.0.22.3`
- 构建工具：autotools（`autoreconf` + `./configure` + `make`）
- 已有 clang/lld/ccache/git build_depends（L130-133）
- build 段结构（L484-496）：`cd ${SRC_ROOT}` → `export CC/CXX` → `autoreconf` → `./configure --prefix=${PREFIX} ...` → `make -j$(nproc)` → `make install` → `mkdir -p ${PREFIX}/etc` + `cp /project/profile ${PREFIX}/etc` → `touch ${PREFIX}/.linyaps_genius` → `chmod -R 755 ${PREFIX}`
- 附带 `profile` 文件（967 字节，可执行），build 段 L494 `cp "/project/profile" "${PREFIX}/etc"` 引用

**验证步骤**：

1. **准备测试 conf**：创建 `examples/vlc-with-patches/CI_ll_org.videolan.www.vlc/custom_debs_urls.conf`，放入一个真实可下载的 deb URL（如 `https://community-packages.deepin.com/beige/pool/main/libx/libxslt1.1_1.1.35-4_amd64.deb`，VLC 运行时依赖 `libxslt1.1` 但 deb 提取仅验证注入/下载/解压流程，不要求该库为 VLC 真正缺失库）：
   ```bash
   CUSTOM_DEB_URLS=(
     "https://community-packages.deepin.com/beige/pool/main/libx/libxslt1.1_1.1.35-4_amd64.deb"
   )
   ```

2. **重新生成 linglong.yaml**：用生成器对 VLC 项目重新生成（需准备 `control_info.yaml`，可从 VLC 的 `buildext.apt` 段反推），传入 `--custom-deb-urls`：
   ```bash
   python3 skills/src2linyaps.debian.build-res-generate/scripts/generate-linglong-yaml.py \
     --control-info examples/vlc-with-patches/CI_ll_org.videolan.www.vlc/control_info.yaml \
     --build-section "cd ${SRC_ROOT}\nexport CC=\"ccache clang\"\nexport CXX=\"ccache clang++\"\nautoreconf --force --install\n./configure --prefix=${PREFIX} ...\nmake -j$(nproc)\nmake install" \
     --build-tool autotools \
     --package-version 3.0.22.3 \
     --defaults skills/config/linglong-defaults.json \
     --custom-deb-urls examples/vlc-with-patches/CI_ll_org.videolan.www.vlc/custom_debs_urls.conf \
     --output examples/vlc-with-patches/CI_ll_org.videolan.www.vlc/linglong.yaml
   ```

3. **检查生成结果**：
   - `build:` 段命令顺序：`autoreconf` → `./configure` → `make` → `make install` → `cp profile` → **`bash /project/linglong/download_custom_debs.sh "${PREFIX}"`** → `touch` → `chmod`
   - `download_custom_debs.sh` 已复制到 `examples/vlc-with-patches/CI_ll_org.videolan.www.vlc/`
   - `custom_debs_urls.conf` 已复制到 `examples/vlc-with-patches/CI_ll_org.videolan.www.vlc/`

4. **验证器校验**：
   ```bash
   python3 skills/src2linyaps.debian.build-res-generate/scripts/validate-linglong-yaml.py \
     examples/vlc-with-patches/CI_ll_org.videolan.www.vlc/linglong.yaml \
     --build-tool autotools \
     --schema skills/config/linglong-schema.yaml \
     --reference skills/src2linyaps.debian.build-res-generate/reference/common-building-rules.yaml
   ```
   验证：退出码 0，注入的 `bash /project/linglong/download_custom_debs.sh "${PREFIX}"` 不触发任何 error。

5. **debug skill 可发现性验证**：确认 `skills/src2linyaps.debug/SKILL.md` 修改后：
   - 阶段二问题类型含「运行库丢失（非 apt 可补齐）」
   - 阶段三修复表含「运行库丢失→`generate-linglong-yaml.py --custom-deb-urls`」分支
   - 重新生成命令代码块含 `--custom-deb-urls <custom_debs_urls.conf>` 可选行
   - 内部 skills 清单 `src2linyaps.debian.build-res-generate` 用途列含「运行库丢失时 `--custom-deb-urls`」
   - 内部资源清单含 `download_custom_debs.sh` 路径

## 假设与应急措施

| 假设 | 风险 | 应急措施 |
|------|------|----------|
| 容器内预装 `wget`、`dpkg`/`dpkg-deb`、`python3` | 容器镜像可能未预装 `wget` | 在 `buildext.apt.build_depends` 追加 `wget`（若验证发现缺失）；当前不主动追加，避免过度依赖 |
| `linglong.yaml` 同级目录映射到容器 `/project/linglong/` | 路径映射可能不同 | 参考 `manifests-for-yaml.md` L305-327：源码目录为 `/project/linglong/sources/`，`linglong.yaml` 同级文件映射到 `/project/linglong/`（补丁文件 `patches/` 已验证此映射） |
| deb URL 可达 | URL 可能 403/404 | 非阻断：`FAIL_COUNT++`，继续处理其余 URL，脚本退出码 0 |
| deb 内容为 FHS 合法目录 | deb 可能含非白名单目录（如 `opt`） | 白名单过滤：非 `IMPORTANT_DIRS` 目录不复制，静默跳过 |

## 文件清单

| 文件 | 操作 | 行数变化 |
|------|------|----------|
| `skills/src2linyaps.debian.build-res-generate/scripts/download_custom_debs.sh` | 新建 | +113 |
| `skills/src2linyaps.debian.build-res-generate/reference/custom_debs_urls_conf_format.md` | 新建 | +35 |
| `skills/src2linyaps.debian.build-res-generate/scripts/generate-linglong-yaml.py` | 修改 | +30（常量+参数+注入+复制） |
| `skills/src2linyaps.debian.build-res-generate/scripts/validate-linglong-yaml.py` | 不修改 | 0 |
| `skills/src2linyaps.debian.build-res-generate/SKILL.md` | 修改 | +15 |
| `skills/src2linyaps.debug/SKILL.md` | 修改 | +15（阶段二类型+阶段三分支+阶段四回退+清单表） |
| `agents/debian-rules-to-linyaps.agent.md` | 修改 | +8 |
| `docs/20261020-custom-deb-extract-plan.md` | 新建 | 本计划全文 |

## 步骤 7：导出实施方案到 `docs/`

**目标文件**：`docs/20261020-custom-deb-extract-plan.md`（新建，与 `docs/20261020-patch-migration-plan.md` 同级，命名规范一致 `YYYYMMDD-<slug>-plan.md`）

**操作**：将本计划文件 `local://build-res-custom-deb-extract-plan.md` 全文复制到 `docs/20261020-custom-deb-extract-plan.md`，作为实施方案归档，供团队查阅与审计。此步骤不改变 skill 代码或工作流逻辑，仅增加文档输出。

**写入命令**：
```bash
cp <session-local-path>/build-res-custom-deb-extract-plan.md docs/20261020-custom-deb-extract-plan.md
```

**验证**：
```bash
# 确认文件存在且非空
test -s docs/20261020-custom-deb-extract-plan.md && echo "OK: $(wc -l < docs/20261020-custom-deb-extract-plan.md) lines"
# 确认包含所有 8 个步骤标题
grep -c '^### 步骤' docs/20261020-custom-deb-extract-plan.md
# 预期输出：7（步骤 1-6 + 步骤 5.5；步骤 7 本身为 ## 二级标题不计入 ### ）
grep -c '^## 步骤 7' docs/20261020-custom-deb-extract-plan.md
# 预期输出：1
```
