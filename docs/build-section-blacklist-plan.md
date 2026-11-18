# Build 段黑名单检测 — 实现方案

## 背景

在 linglong.yaml 的 `build:` 字段中，`DESTDIR` 变量赋值（如 `DESTDIR=${PREFIX}`、`DESTDIR=/usr`）仅应出现在 **make** 工程中。对于 cmake、meson、autotools 等使用 `--prefix`/`-DCMAKE_INSTALL_PREFIX` 配置安装路径的工具，同时使用 `DESTDIR` 会导致安装目录错误嵌套（如 `${PREFIX}${PREFIX}`）。

## 目标

在 `build-res-generate` skill 中追加黑名单检测机制，根据构建工具类型（由 `src2linyaps.source.detect-tool` 判断），检测 `build:` 字段是否包含非法词 `DESTDIR`。

## 涉及文件

| # | 操作 | 文件 |
|---|------|------|
| 1 | **CREATE** | `skills/src2linyaps.debian.build-res-generate/build-section-blacklist.yaml` |
| 2 | **MODIFY** | `skills/src2linyaps.debian.build-res-generate/scripts/generate-linglong-yaml.py` |
| 3 | **MODIFY** | `skills/src2linyaps.debian.build-res-generate/scripts/validate-linglong-yaml.py` |
| 4 | **MODIFY** | `skills/src2linyaps.debian.build-res-generate/SKILL.md` |
| 5 | **MODIFY** | `agents/debian-rules-to-linyaps.agent.md` |
| 6 | **SYNC** | `for-multica/agent.md`（与主 agent 同步变更） |

## 详细设计

### 1. 黑名单配置文件 `build-section-blacklist.yaml`

放置在 skill 根目录（`skills/src2linyaps.debian.build-res-generate/`），按构建工具类型映射非法词：

```yaml
blacklist:
  cmake:     [DESTDIR]
  meson:     [DESTDIR]
  autotools: [DESTDIR]
  make:      []
  unknown:   [DESTDIR]
```

- `make` 类型允许 `DESTDIR`（空列表）
- `unknown` 类型保守禁止（安全优先）

### 2. 检测逻辑

#### 检测模式

使用正则 `DESTDIR=\S+` 匹配 `DESTDIR=` 后跟任意非空白字符，覆盖：
- `DESTDIR=${PREFIX}`
- `DESTDIR=/usr`
- `DESTDIR=xxx cmake install`
- `DESTDIR=xxx make install`
- `DESTDIR=xxx meson install`

#### 内联函数（各脚本自行实现，代码一致）

```python
def load_blacklist(path=None):
    """加载黑名单配置，path=None 时自动定位到 skill 目录"""
    if path is None:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        path = os.path.join(script_dir, '..', 'build-section-blacklist.yaml')
    if not os.path.isfile(path):
        return None
    with open(path) as f:
        config = yaml.safe_load(f)
    return config.get('blacklist', {})

def check_blacklist(build_section, build_tool, blacklist):
    """检查 build 段是否包含黑名单词，返回错误列表"""
    errors = []
    if build_tool not in blacklist:
        return errors
    forbidden = blacklist.get(build_tool, [])
    for word in forbidden:
        pattern = re.compile(rf'{re.escape(word)}=\S+')
        if pattern.search(build_section):
            errors.append(
                f"build section contains '{word}=<value>' "
                f"which is not allowed for build tool type '{build_tool}'"
            )
    return errors
```

### 3. `generate-linglong-yaml.py` 变更

**新增参数**：
- `--build-tool`：choices=`cmake|meson|make|autotools|unknown`，默认 `unknown`
- `--blacklist`：黑名单配置文件路径，默认自动定位到 `../build-section-blacklist.yaml`

**校验时机**：
`build_yaml()` 执行之后、写入文件之前，调用 `check_blacklist()`。若命中黑名单，打印错误信息并 `sys.exit(1)`。

**调用示例**：
```bash
python3 generate-linglong-yaml.py \
  --build-tool cmake \
  --blacklist skills/src2linyaps.debian.build-res-generate/build-section-blacklist.yaml \
  --control-info ... \
  --build-section "..." \
  --package-version ... \
  --defaults skills/config/linglong-defaults.json \
  --output output/.../linglong.yaml
```

### 4. `validate-linglong-yaml.py` 变更

**新增参数**：
- `--build-tool`：choices=`cmake|meson|make|autotools|unknown`，默认 `unknown`

**校验时机**：
在 `validate()` 函数中新增 `blacklist` 检查项，作为校验阶段的二次保障。

### 5. Workflow 集成

#### 路径 A（debian 规则分析）

在 Step A4 调用 `generate-linglong-yaml.py` 之前，先调用 `detect-tool` 获取工具类型，然后传入 `--build-tool`：

```bash
# Step A4 前置: 检测构建工具类型
bash skills/src2linyaps.source.detect-tool/scripts/detect-build-tool.sh <project_path>
# → tool_type: cmake

# 生成 linglong.yaml
python3 generate-linglong-yaml.py \
  --build-tool cmake \
  ...
```

#### 路径 B（源码分析 fallback）

Step B1 已由 `detect-tool` 获取工具类型，直接传入 `--build-tool`。

#### Phase 3 校验

```bash
python3 validate-linglong-yaml.py \
  output/.../linglong.yaml \
  --build-tool cmake \
  --schema skills/config/linglong-schema.yaml
```

### 6. `debian-rules-to-linyaps.agent.md` 变更

- Step A4 脚本调用示例增加 `--build-tool` 参数
- Phase 3 校验示例增加 `--build-tool` 参数
- 约束条件中增加 DESTDIR 黑名单说明

## 同步到 `for-multica/agent.md`

`for-multica/agent.md` 是 Multica 多智能体平台的 agent 版本，对应主 agent `agents/debian-rules-to-linyaps.agent.md`（第 343 行声明 `对应主 Agent：agents/debian-rules-to-linyaps.agent.md`）。

需要同步以下变更：

### 1. Step A4 — 工程生成

在调用 `src2linyaps.debian.build-res-generate` skill 时，需要在 Step A4 之前先调用 `detect-tool` 获取构建工具类型，然后传入 `--build-tool` 参数。

### 2. Step A5 — 校验

校验命令增加 `--build-tool` 参数。

### 3. Path B — 源码 Fallback

Step B1 已检测工具类型，Step B3 生成工程时需传入 `--build-tool`。

### 4. 约束区段

追加 DESTDIR 黑名单约束说明。

| 场景 | 行为 |
|------|------|
| 黑名单文件不存在 | 跳过校验（`load_blacklist()` 返回 `None`） |
| `--build-tool` 未指定（默认 `unknown`） | 保守禁止 `DESTDIR` |
| 检测到非法词 | `print("ERROR: ...")` → `sys.exit(1)`，阻止生成/校验通过 |