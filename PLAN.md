# 修正方案：让 `common-building-rules.yaml` 成为 build section 的生成源

## 问题

`src2linyaps.debian.build-res-generate` 错误地无视 debian rules。引入 `common-building-rules` 常见编译规则后，生成的 build section 不包含对原 debian rules 的分析。

### 根因

1. `analyze-rules.py` 在 `generate_build_section()` 中使用**硬编码模板**生成 build section，与 `common-building-rules.yaml` 定义的规范模式不一致
2. `generate-linglong-yaml.py` 虽然引入了 `common-building-rules.yaml`，但仅用于**校验**（check required commands / forbidden patterns），未用于**生成**
3. 生成的 build section 含 `DESTDIR=${prefix}` 等被参考文件标记为 forbidden 的内容，导致校验阻断

### VLC 实例对比

| 来源 | autotools build section |
|------|------------------------|
| `common-building-rules.yaml` (参考) | `./configure --prefix=...` + `make` + `make install` |
| `analyze-rules.py` (当前生成) | `./configure --prefix=${PREFIX} --host=` + `make -j$(nproc)` + `make install DESTDIR=${prefix}` ← **DESTDIR 被 forbidden** |
| `vlc.linglong.yaml` (期望输出) | `./configure --prefix=${PREFIX}` + `make -j$(nproc)` + `make install` |

---

## 角色分工

```
                debian/rules
                    │
                    ├─── analyze-rules.py (机械分析)
                    │       └── build_tool, build_args, baseline, resources
                    │
                    └─── LLM (语义分析, 在 analyze-rules SKILL.md 中指引)
                            └── extra_args + build_section (完整自定)
                                    │
                                    ▼
                    generate-linglong-yaml.py
                        │
                        ├── 主: 使用 --build-section (LLM 提供)
                        ├── 补: 对照 common-building-rules.yaml 补充缺失命令
                        ├── 阻: 禁止 forbidden patterns
                        ├── 注: 注入 --build-args + --extra-args 到 configure 命令
                        ├── 标准化: ${PREFIX} 路径替换
                        └── 输出: linglong.yaml
```

---

## 改动的文件清单

| # | 文件 | 改动类型 |
|---|------|---------|
| 1 | `skills/src2linyaps.debian.analyze-rules/SKILL.md` | 新增 LLM 语义分析步骤 (3.2) |
| 2 | `skills/src2linyaps.debian.build-res-generate/scripts/generate-linglong-yaml.py` | 修改核心生成逻辑 |
| 3 | `skills/src2linyaps.debian.build-res-generate/SKILL.md` | 更新输入表和工作流程 |
| 4 | `agents/debian-rules-to-linyaps.agent.md` | 更新 Step A3 拆分 + Step A4 调用 |
| 5 | `for-multica/agent.md` | 同步 Step A3 拆分 + Step A4 调用 |

---

## 各文件具体改动

### 1. `skills/src2linyaps.debian.analyze-rules/SKILL.md`

**工作流程**：第 5 步（运行脚本）后新增第 6 步 LLM 语义分析

```markdown
6. **LLM 语义分析 `debian/rules`**：
   a. 读取 `debian/rules` 完整内容
   b. 识别额外有意义的编译参数：
      - 关键 `--enable-*` / `--disable-*`（过滤平台无关项如 `--disable-d3d11va`、`--disable-wasapi`）
      - `--with-*` / `--without-*`
      - `CFLAGS` / `CXXFLAGS` / `LDFLAGS` 环境变量
      - 其他自定义参数（如 `--docdir`、`--with-binary-version`）
   c. 与 `build_args`（机械分析输出）去重
   d. 输出 `extra_args`（字符串，追加到 configure 命令末尾）
   e. 输出 `build_section`（完整自定义构建段，包含 LLM 分析的所有参数）
```

**输出示例**新增 `extra_args` 字段：

```yaml
build_section: |
  ./configure --prefix=${PREFIX} --enable-qt --enable-dbus --enable-udev
  make -j$(nproc)
  make install
extra_args: "--enable-qt --enable-dbus --enable-udev"
```

---

### 2. `skills/src2linyaps.debian.build-res-generate/scripts/generate-linglong-yaml.py`

#### 新增 CLI 参数

```python
parser.add_argument('--build-args', default='',
                    help='build args JSON from analyze-rules.py (e.g. \'[{"name":"prefix","default":"${PREFIX}"}]\')')
parser.add_argument('--extra-args', default='',
                    help='extra configure args from LLM semantic analysis (e.g. "--enable-qt --enable-dbus")')
```

#### 新增函数 `inject_args_to_configure()`

```python
def inject_args_to_configure(build_section: str, build_args: list, extra_args: str) -> str:
    """将 build_args 和 extra_args 注入到 build_section 的 configure 命令中。
    
    - build_args: 从 analyze-rules.py 提取的基础参数, 替换 configure 行中同名参数值
    - extra_args: LLM 语义分析得到的额外参数, 追加到 configure 行末尾
    - 空值参数自动省略
    """
    lines = build_section.split('\n')
    result = []
    for line in lines:
        stripped = line.strip()
        # 识别 configure 行: ./configure ... 或 cmake ... -D... 或 meson setup ...
        if stripped.startswith('./configure ') or stripped.startswith('cmake ') or stripped.startswith('meson '):
            # 替换 build_args 中非空值
            for arg in build_args:
                name = arg.get('name', '')
                value = arg.get('default', '')
                if not value:
                    continue
                if stripped.startswith('./configure '):
                    # 替换 --name=value
                    pattern = rf'--{re.escape(name)}=\S+'
                    replacement = f'--{name}={value}'
                    if re.search(pattern, stripped):
                        stripped = re.sub(pattern, replacement, stripped)
                    else:
                        stripped += f' --{name}={value}'
                elif stripped.startswith('cmake '):
                    # 替换 -DNAME=value
                    pattern = rf'-D{re.escape(name)}=\S+'
                    replacement = f'-D{name}={value}'
                    if re.search(pattern, stripped):
                        stripped = re.sub(pattern, replacement, stripped)
                    else:
                        stripped += f' -D{name}={value}'
                elif stripped.startswith('meson '):
                    # 替换 -Dname=value
                    pattern = rf'-D{re.escape(name)}=\S+'
                    replacement = f'-D{name}={value}'
                    if re.search(pattern, stripped):
                        stripped = re.sub(pattern, replacement, stripped)
                    else:
                        stripped += f' -D{name}={value}'
            # 追加 extra_args
            if extra_args:
                stripped += f' {extra_args}'
            result.append(line.replace(line.strip(), stripped))
        else:
            result.append(line)
    return '\n'.join(result)
```

#### 新增函数 `supplement_build_section()`

```python
def supplement_build_section(build_section: str, build_tool: str, reference: dict) -> str:
    """检查 build_section 是否包含 reference 中定义的必选命令, 缺失则补充。"""
    if reference is None:
        return build_section
    tool_ref = reference.get('tools', {}).get(build_tool, {})
    if not tool_ref:
        return build_section

    commands = _split_commands(build_section)
    supplement_lines = []

    for cmd_def in tool_ref.get('commands', []):
        if not _matches_command_def(cmd_def, commands):
            # 从参考模板生成补充命令
            desc = cmd_def.get('description', '')
            patterns = cmd_def.get('patterns', [])
            if 'one_of' in cmd_def:
                # 使用第一个备选方案
                patterns = cmd_def['one_of'][0].get('patterns', [])
            if patterns:
                supplement_line = ' '.join(patterns)
                supplement_lines.append(supplement_line)
                print(f"  [supplement] added missing command: {desc}", file=sys.stderr)

    if supplement_lines:
        build_section = build_section.rstrip('\n') + '\n' + '\n'.join(supplement_lines) + '\n'

    return build_section
```

#### `main()` 核心流程更新

```python
def main():
    # ... 解析参数 (原有) ...

    # 加载 reference
    reference = load_reference(args.reference if args.reference else None)

    # 解析 build_args
    build_args = []
    if args.build_args:
        try:
            build_args = json.loads(args.build_args)
        except json.JSONDecodeError as e:
            print(f"  [warn] failed to parse --build-args JSON: {e}", file=sys.stderr)

    # 确定 build_section
    build_section = args.build_section if args.build_section else ''
    if not build_section and reference:
        # 从 reference 生成
        build_section = generate_build_section_from_reference(args.build_tool, build_args, reference)
    elif not build_section:
        # fallback 到 defaults
        build_section = defaults.get('build_section_fallback', '')

    # 注入参数
    build_section = inject_args_to_configure(build_section, build_args, args.extra_args)

    # 补充缺失命令
    if reference:
        build_section = supplement_build_section(build_section, args.build_tool, reference)

    # 检查 forbidden patterns
    if reference:
        _, errors = check_against_reference(build_section, args.build_tool, reference)
        if errors:
            for e in errors:
                print(f"ERROR: {e}", file=sys.stderr)
            sys.exit(1)

    # 路径规范化 (原有)
    build_section = build_section.replace('${prefix}', '${PREFIX}')
    build_section = replace_hardcoded_prefixes(build_section)

    # 追加 touch/chmod (原有)
    if not build_section.endswith('\n'):
        build_section += '\n'
    build_section += 'touch ${PREFIX}/.linyaps_genius\n'
    build_section += 'chmod -R 755 ${PREFIX}\n'

    # 构建 YAML 并写入 (原有)
    # ...
```

#### 新增辅助函数 `generate_build_section_from_reference()`

```python
def generate_build_section_from_reference(build_tool: str, build_args: list, reference: dict) -> str:
    """从 common-building-rules.yaml 生成规范 build section 模板。"""
    if reference is None:
        return ''

    tool_ref = reference.get('tools', {}).get(build_tool, {})
    if not tool_ref:
        return ''

    # 生成命令模板
    lines = []
    for cmd_def in tool_ref.get('commands', []):
        patterns = cmd_def.get('patterns', [])
        if 'one_of' in cmd_def:
            # 使用第一个备选方案
            patterns = cmd_def['one_of'][0].get('patterns', [])
        if patterns:
            # 排除标记 (如 "install", "DESTDIR=") 不属于命令本身
            exclude = cmd_def.get('exclude', [])
            cmd_str = ' '.join(p for p in patterns if p not in exclude)
            if cmd_str:
                lines.append(cmd_str)

    # 用 build_args 填充
    result = '\n'.join(lines)
    if build_args:
        result = inject_args_to_configure(result, build_args, '')
    return result
```

---

### 3. `skills/src2linyaps.debian.build-res-generate/SKILL.md`

#### 输入表新增

```markdown
| `build_args` | list of dict | 构建参数（从 `analyze-rules` 机械分析获取） | `analyze-rules` 输出 |
| `extra_args` | string | 额外编译参数（LLM 语义分析 `debian/rules` 获取） | `analyze-rules` 输出 |
```

#### 工作流程更新

```markdown
## 工作流程

1. 加载 `analyze-control` 输出的 control_info YAML
2. 根据 `buildDepends` 是否非空决定是否含 `build_depends` 段
3. 加载 `skills/config/linglong-defaults.json` 获取默认值
4. 按优先级解析各字段：CLI 参数 > defaults JSON > 硬编码默认值
5. 对 `buildDepends` 剥离版本约束（`cmake (>= 3.16~)` → `cmake`）
6. 构建 build section：
   a. 若 `--build-section` 提供 → 使用 LLM 自定义构建段
   b. 否则 → 从 `referance/common-building-rules.yaml` 按工具类型生成规范模板
   c. 注入 `build_args`（非空参数替换 configure 行中同名值）
   d. 追加 `extra_args` 到 configure 命令行末尾
   e. 对照 reference 补充缺失的必选命令
   f. 检查 forbidden patterns，命中则阻断
7. 路径规范化（`${prefix}` → `${PREFIX}`、硬编码路径替换）
8. 追加 `touch ${PREFIX}/.linyaps_genius` 和 `chmod -R 755 ${PREFIX}`
9. 构建完整 YAML 结构并写入输出文件
```

#### 更新"Build 段参考约束"

```markdown
### Build 段参考约束

`referance/common-building-rules.yaml` 同时用于**生成**和**校验**：

- **生成阶段**：脚本通过 `common-building-rules.yaml` 生成规范构建命令模板，注入 `build_args` 和 `extra_args` 参数，补充缺失的必选命令
- **校验阶段**：对最终 build section 执行双重检查：
  - **必需命令检查**：build 段必须包含该工具类型的规范构建命令。缺失命令自动从参考补充，并打印 `[supplement]` 提示
  - **禁用参数检查**：build 段禁止出现黑名单参数（如 cmake 工程中的 `DESTDIR=`）。检测到禁用参数时打印 `ERROR` 并阻断流程（exit 1）
  - **命令拆分规则**：先合并 `\` 续行，再按 `&&`/`;`/`||`/`\n` 拆分为独立命令，逐条匹配
```

---

### 4. `agents/debian-rules-to-linyaps.agent.md`

#### Step A3 拆分

**当前** (lines 272-287):

```markdown
#### Step A3: Rules 分析

调用 `src2linyaps.debian.analyze-rules` skill：

```yaml
# 输入
project_path: <项目路径>
debian_path: <项目路径>/debian
control_info: <上一步输出的 control 信息>
```

**执行方式**：
- 读取 `debian/rules`, `debian/changelog`, `debian/*.install` 等文件
- 执行 `scripts/analyze-rules.py <project_path> <debian_path> [control_yaml]`
- 输出最终 YAML（含 build_section、baseline、resources）
```

**改为**:

```markdown
#### Step A3: Rules 分析

调用 `src2linyaps.debian.analyze-rules` skill：

```yaml
# 输入
project_path: <项目路径>
debian_path: <项目路径>/debian
control_info: <上一步输出的 control 信息>
```

**A3.1 机械分析（脚本）**
- 执行 `scripts/analyze-rules.py <project_path> <debian_path> [control_yaml]`
- 输出: `build_tool`, `build_args`, `baseline`, `resources`

**A3.2 LLM 语义分析**
- 读取 `debian/rules` 完整内容
- 按 `src2linyaps.debian.analyze-rules` SKILL.md 指引执行语义分析
- 识别额外编译参数 → 输出 `extra_args`
- 输出完整 `build_section`（含 LLM 分析参数）
- 合并 A3.1 + A3.2 输出 → 最终 YAML（含 `build_section`, `build_tool`, `build_args`, `extra_args`, `baseline`, `resources`）
```

#### Step A4 调用更新

**当前** (lines 308-315):

```bash
python3 generate-linglong-yaml.py \
  --control-info <control_info.yaml> \
  --build-section "<build_section>" \
  --package-version <baseline> \
  --build-tool <tool_type> \
  --defaults skills/config/linglong-defaults.json \
  --output output/${tag}/linglong.yaml
```

**改为**:

```bash
python3 generate-linglong-yaml.py \
  --control-info <control_info.yaml> \
  --build-section "<build_section>" \
  --build-tool <tool_type> \
  --build-args '<build_args_json>' \
  --extra-args '<extra_args_string>' \
  --package-version <baseline> \
  --defaults skills/config/linglong-defaults.json \
  --output output/${tag}/linglong.yaml
```

---

### 5. `for-multica/agent.md`

与 `agents/debian-rules-to-linyaps.agent.md` 同步改动。

#### Step A3 拆分 (当前 lines 186-190)

**当前**:

```markdown
#### Step A3: Rules 分析
调用 `src2linyaps.debian.analyze-rules` skill：
- 读取 `debian/rules`、`debian/changelog`、`*.install` / `*.links` / `*.docs` / `*.manpages` 等文件
- 执行 `analyze-rules.py` → 输出 build_section shell 脚本
- 输出：最终 YAML（含 build_section、baseline、resources）
```

**改为** (同 `agents/` 版本):

```markdown
#### Step A3: Rules 分析

调用 `src2linyaps.debian.analyze-rules` skill：

**A3.1 机械分析（脚本）**
- 执行 `scripts/analyze-rules.py <project_path> <debian_path> [control_yaml]`
- 输出: `build_tool`, `build_args`, `baseline`, `resources`

**A3.2 LLM 语义分析**
- 读取 `debian/rules` 完整内容
- 按 `src2linyaps.debian.analyze-rules` SKILL.md 指引执行语义分析
- 识别额外编译参数 → 输出 `extra_args`
- 输出完整 `build_section`（含 LLM 分析参数）
- 合并 A3.1 + A3.2 输出 → 最终 YAML（含 `build_section`, `build_tool`, `build_args`, `extra_args`, `baseline`, `resources`）
```

#### Step A4 调用更新 (当前 lines 212-218)

**当前**:

```bash
python3 generate-linglong-yaml.py \
  --build-tool <tool_type> \
  --control-info <control_info.yaml> \
  --build-section "<build_section>" \
  --package-version <baseline> \
  --defaults skills/config/linglong-defaults.json \
  --output <output_dir>/CI_ll_<package_id>/linglong.yaml
```

**改为**:

```bash
python3 generate-linglong-yaml.py \
  --build-tool <tool_type> \
  --control-info <control_info.yaml> \
  --build-section "<build_section>" \
  --build-args '<build_args_json>' \
  --extra-args '<extra_args_string>' \
  --package-version <baseline> \
  --defaults skills/config/linglong-defaults.json \
  --output <output_dir>/CI_ll_<package_id>/linglong.yaml
```

---

## 不变的文件

| 文件 | 原因 |
|------|------|
| `scripts/analyze-rules.py` | 机械分析逻辑保留，输出 `build_args` 供下游使用 |
| `scripts/validate-linglong-yaml.py` | 校验逻辑不变，仍用于 Phase 3 最终校验 |
| `referance/common-building-rules.yaml` | 参考定义不变，同时用于生成和校验 |
| `build-section-blacklist.yaml` | DESTDIR 黑名单不变 |
| `skills/config/linglong-defaults.json` | 默认值配置不变 |
| `agent-config.json` (两个版本) | 配置不变 |

---

## VLC 实例验证

### 输入

| 参数 | 值 |
|------|-----|
| `build_tool` | `autotools` |
| `build_args` | `[{"name": "prefix", "default": "${PREFIX}"}]` |
| `extra_args` | `"--enable-qt --enable-dbus --enable-udev"` |
| `build_section` (LLM) | `./configure --prefix=${PREFIX} --enable-qt --enable-dbus --enable-udev\nmake -j$(nproc)\nmake install` |

### 流程

| 步骤 | 操作 | 结果 |
|------|------|------|
| 1 | 使用 `--build-section` (LLM 提供) | `./configure --prefix=${PREFIX} --enable-qt --enable-dbus --enable-udev\nmake -j$(nproc)\nmake install` |
| 2 | `inject_args`: build_args 中 prefix=${PREFIX} 已存在 | 不变 |
| 3 | `supplement`: 检查 ./configure ✓, make ✓, make install ✓ | 无需补充 |
| 4 | 检查 forbidden: DESTDIR= 不存在 | 通过 |
| 5 | 路径规范化: 无硬编码路径 | 通过 |
| 6 | 追加 touch/chmod | `touch ${PREFIX}/.linyaps_genius\nchmod -R 755 ${PREFIX}` |
| 7 | 写入 linglong.yaml | 完成 |

### 最终 build section

```yaml
build: |
  ./configure --prefix=${PREFIX} --enable-qt --enable-dbus --enable-udev
  make -j$(nproc)
  make install
  touch ${PREFIX}/.linyaps_genius
  chmod -R 755 ${PREFIX}
```

---

## 执行顺序建议

1. `generate-linglong-yaml.py` — 核心逻辑变更，最影响产出的文件
2. `skills/src2linyaps.debian.build-res-generate/SKILL.md` — 文档更新，与脚本同步
3. `skills/src2linyaps.debian.analyze-rules/SKILL.md` — 新增 LLM 语义分析指引
4. `agents/debian-rules-to-linyaps.agent.md` — 编排更新
5. `for-multica/agent.md` — 同步编排更新