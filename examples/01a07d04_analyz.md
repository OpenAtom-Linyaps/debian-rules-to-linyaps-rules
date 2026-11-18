# 01a07d04 会话分析结论：com.sweethome3d 打包场景阻塞分析

## 1. 分析目标

分析会话 `01a07d04-296b-770a-af8d-33dc87f36a64` 中观察到的 `com.sweethome3d`（LIN-3478）打包场景失败：

1. **提交失败**：pre-commit guard 阻断了包含缓存删除记录的暂存提交。
2. **指派阻塞**：`linyaps-src-init-dispatch` 将完整 agent 列表 JSON 作为 Python 命令行参数传递，触发 `Argument list too long`。
3. **环境变量缺失**：`MULTICA_ISSUE_TASK_ID` 未导出，导致初始化流程无法安全开始。

本次分析仅基于会话数据与源码静态审查，不修改任何源代码。

---

## 2. 会话概要

| 字段 | 值 |
|---|---|
| 会话 ID | `01a07d04-296b-770a-af8d-33dc87f36a64` |
| 创建时间 | 2026-09-07T17:56:59.883Z |
| 更新时间 | 2026-09-07T18:07:17.516Z |
| 工作目录 | `/home/deepin/multica_workspaces/linyaps-708b8f8fedab/lin-3480-cb280b4764ae/workdir` |
| 当前 issue | LIN-3480 `2801b000-8246-45fd-8778-ebd7c868a808`（org.kde.kaffeine） |
| 分析对象 issue | LIN-3478 `6b05d341-05ab-4f30-9867-fdcb60052e0f`（com.sweethome3d） |
| 模型 | gpt-5.6-luna |

### 会话统计（JSON `stats` 字段）

| 指标 | 值 |
|---|---|
| 总消息数 | 99 |
| 用户消息 | 1 |
| 助手消息 | 27 |
| 工具消息 | 71 |
| 输入 Token | 419,770 |
| 输出 Token | 14,750 |
| 缓存读取 | 1,789,440 |
| 缓存写入 | 0 |
| 缓存命中率 | 80.99%（1,789,440 / 2,209,210） |

### 工具调用分布（`toolCallDetails` 数组，共 71 次）

| 工具 | 调用次数 |
|---|---|
| bash | 37 |
| read | 28 |
| glob | 4 |
| write | 2 |

### 会话工作摘要

本会话是 kaffeine（LIN-3480）的 packer 会话。会话发现 kaffeine 在共享打包仓库中尚无项目目录，遂将源码初始化任务指派给 `linyaps-src-init-2`。在调查过程中，会话检索了 sweethome3d（LIN-3478）的 issue 评论与父 issue 信息，发现了 sweethome3d 打包流程中遭遇的三重阻塞。

---

## 3. 阻塞时间线

以下时间线基于会话中检索到的 issue 评论，所有评论均从 `multica issue comment list` 命令输出中获取。

| 时间 (UTC) | 评论 ID | 作者 | 事件 |
|---|---|---|---|
| 2026-09-06T15:42:15Z | `01a07762` | linyaps-src-init-3 | **RC1 触发**：sweethome3d 初始化被阻断——`MULTICA_ISSUE_TASK_ID` 未导出，禁止从 issue ID 推断。 |
| 2026-09-06T15:43:35Z | `01a07763` | linyaps-src-init-3 | **RC1 中文重述**：明确"不能安全开始或完成 `com.sweethome3d` 的初始化流程"，请求重新触发并注入环境变量。 |
| 2026-09-06T16:12:17Z | `01a0777d` | linyaps-src-init-1 | **RC1 同类阻断**：kaffeine（LIN-3480）同样因 `MULTICA_ISSUE_TASK_ID` 未导出被阻断——证明 RC1 是系统性平台问题。 |
| 2026-09-07T08:08:40Z | `01a07ae9` | linyaps-src-init-2 | **RC2 触发**：sweethome3d 配方已生成且构建验证通过，但 `linyaps-git-workflow` 清理已跟踪的无关缓存 `CI_ll_alienblaster/alienblaster_1.1.0.0_x86_64_binary.layer` 后，pre-commit guard 拒绝该删除的暂存记录。配方未提交、未指派 packer。 |
| 2026-09-07T08:09:26Z | `01a07aea` | 成员（人类） | 手动指令："re-commit"，要求重新提交。 |
| 2026-09-07T08:13:09Z | `01a07aed` | linyaps-src-init-2 | **RC2 绕过 + RC3 触发**：重新提交成功（commit `9c680627f21ce4f12a2a42dd3fb28614d66820ed` 已在 master）。但后续 packer 指派被 `linyaps-src-init-dispatch` 阻断——脚本将完整 agent 列表作为 Python 命令行参数传递，触发 `Argument list too long`。 |
| 2026-09-07T09:00:49Z | `01a07b19` | agent (641bbb1b) | **源码适配完成**：提交 `d6c319c7 feat: adapt com.sweethome3d source package`，Ant 编译 `BUILD SUCCESSFUL`。但运行时输出检查报 `/opt/apps/com.sweethome3d/files/bin/sweethome3d: No such file or directory`，`ll-builder export --layer` 失败。此为应用层问题，非工作流基础设施 bug。 |

---

## 4. 根本原因分析

### RC1 — `MULTICA_ISSUE_TASK_ID` 未导出（平台环境配置问题）

**严重度**：阻断初始化流程入口

**根因**：平台在触发任务时未向运行环境注入 `MULTICA_ISSUE_TASK_ID` 环境变量。

**代码证据**（`dispatch.sh:57-62`）：

```bash
get_issue_id() {
  local env_id="${MULTICA_ISSUE_TASK_ID:-}" id="${env_id:-$ISSUE_ID_ARG}"
  [[ -n "$ISSUE_ID_ARG" && -n "$env_id" && "$ISSUE_ID_ARG" != "$env_id" ]] && return 3
  [[ -n "$id" ]] && is_uuid "$id" || return 4
  printf '%s\n' "$id"
}
```

`get_issue_id()` 首先读取 `MULTICA_ISSUE_TASK_ID`，若为空则回退到 `ISSUE_ID_ARG`。但工作流约束明确禁止从 issue ID 推断任务 ID，因此当环境变量缺失时，整个初始化流程在入口处即被阻断。

**会话证据**：
- 评论 `01a07762`（2026-09-06T15:42:15Z）："Blocked before conversion: `MULTICA_ISSUE_TASK_ID` is unset."
- 评论 `01a07763`（2026-09-06T15:43:35Z）："已阻塞：运行环境未导出必需的 `MULTICA_ISSUE_TASK_ID`...不能安全开始或完成 `com.sweethome3d` 的初始化流程"
- 评论 `01a0777d`（2026-09-06T16:12:17Z）：kaffeine（LIN-3480）同样被阻断——证明此为系统性问题，非个例。

**影响范围**：同时影响 sweethome3d（LIN-3478）和 kaffeine（LIN-3480），以及可能所有同期触发的 issue。

**修复方向**：平台在任务触发时确保注入 `MULTICA_ISSUE_TASK_ID`（小写 UUID 格式）。此为环境配置修复，非代码修复。

---

### RC2 — pre-commit guard 阻断缓存删除暂存（核心代码 Bug）

**严重度**：阻断 Git 提交，导致配方无法入库

**根因**：`pre-commit-guard.sh:59` 使用 `git diff --cached --name-only --relative` 列出所有暂存文件，不区分"暂存新增"与"暂存删除"。当 `clean_project_cache.sh` 删除已跟踪的缓存文件后，`git add .` 将删除记录暂存，guard 仍将匹配到 `.layer` 路径并阻断提交。

**触发链**：

```
git-workflow.sh:157-159  → clean_project_cache 对每个 CI_ll_* 目录执行清理
clean_project_cache.sh:100 → remove_glob "*.layer" 删除已跟踪的 .layer 文件
git-workflow.sh:167       → git add . 暂存删除记录
pre-commit-guard.sh:59    → git diff --cached --name-only --relative 列出暂存文件（含删除路径）
pre-commit-guard.sh:67    → grep -E '\.layer$' 匹配到删除路径中的 .layer
pre-commit-guard.sh:73    → exit 1 阻断提交
```

**代码证据**：

`pre-commit-guard.sh:59`（Bug 所在）：
```bash
CACHED_FILES=$(git diff --cached --name-only --relative 2>/dev/null || true)
```
此命令列出所有暂存变更的文件路径，包括被删除的文件。删除路径仍包含原始文件名（如 `CI_ll_alienblaster/alienblaster_1.1.0.0_x86_64_binary.layer`），因此 `grep -E '\.layer$'` 会匹配并阻断。

`pre-commit-guard.sh:47`（匹配模式）：
```bash
DEFAULT_PATTERN='(\.layer$|\.uab$|(^|/)linglong/|(^|/)bins/|(^|/)reports/|(^|/)build_cache/|(^|/)\.linyaps-locks/)'
```

`pre-commit-guard.sh:67-73`（阻断逻辑）：
```bash
HITS=$(echo "$CACHED_FILES" | grep -E "$PATTERN" || true)
if [[ -n "$HITS" ]]; then
  echo "[守卫] 阻断：检测到缓存文件被暂存，禁止提交：" >&2
  echo "$HITS" | sed 's/^/    /' >&2
  echo "请先运行 clean_project_cache.sh <project_dir> 清理缓存后重试。" >&2
  exit 1
fi
```

`git-workflow.sh:154-174`（调用链）：
```bash
# 清理构建缓存
while IFS= read -r -d '' proj; do
  clean_project_cache "$proj"
done < <(find "$INIT_REPO_DIR" -maxdepth 1 -type d -name 'CI_ll_*' -print0 2>/dev/null)

# ... sync_upstream ...

# 暂存变更
git add . 2>/dev/null || true

# 提交前守卫
if ! pre_commit_guard "$INIT_REPO_DIR"; then
  echo "{\"committed\":false,\"commit_sha\":\"\",\"packages\":[],\"blocked\":\"pre_commit_guard\"}"
  exit 0
fi
```

`clean_project_cache.sh:76-90,100`（删除逻辑）：
```bash
remove_glob() {
  local pattern="$1"
  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    removed_count=$((removed_count + 1))
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "[dry-run] 将删除: $f"
    else
      rm -f "$f"
      echo "[清理] 已删除: $f"
    fi
  done < <(find "$PROJECT_DIR" -maxdepth 3 -type f -name "$pattern" 2>/dev/null)
}

# ...
remove_glob "*.layer"
```

**会话证据**：
- 评论 `01a07ae9`（2026-09-07T08:08:40Z）："当前阻塞于 Git 工作流：`linyaps-git-workflow` 会清理已跟踪的无关缓存 `CI_ll_alienblaster/alienblaster_1.1.0.0_x86_64_binary.layer`，随后 pre-commit guard 又拒绝该删除的暂存记录。因此本配方未提交、未指派 packer。需要修复该 guard 对缓存删除的处理后重新触发提交和打包指派。"

**问题本质**：guard 的设计意图是阻止"缓存文件被新增暂存"（误提交缓存），但实际行为是阻止"缓存文件路径出现在暂存区"——无论新增还是删除。`clean_project_cache.sh` 删除已跟踪缓存文件是正确行为，但 guard 将此删除误判为"缓存被提交"并阻断。

**修复方案**：`pre-commit-guard.sh:59` 添加 `--diff-filter=d` 排除删除记录：

```bash
# 修复前
CACHED_FILES=$(git diff --cached --name-only --relative 2>/dev/null || true)

# 修复后
CACHED_FILES=$(git diff --cached --name-only --diff-filter=d --relative 2>/dev/null || true)
```

`--diff-filter=d` 使 `git diff` 仅列出新增（A）和修改（M）的暂存文件，排除删除（D）记录。这样 guard 只阻止"缓存文件被新增暂存"，不再阻断"缓存文件被删除暂存"。

**绕过情况**：评论 `01a07aea`（人类指令 "re-commit"）后，评论 `01a07aed` 确认重新提交成功（commit `9c680627`）。agent 通过手动方式绕过了 guard（可能直接执行 `git commit` 跳过 workflow 脚本），但根因未修复。

---

### RC3 — dispatch 脚本参数过长（次要代码 Bug）

**严重度**：阻断 packer 指派，导致构建产物无法流转

**根因**：`dispatch.sh:77` 在 `assign_packer` 动作中，将完整的 agent 列表 JSON（`$AGENTS_JSON` 和 `$PLATFORM_JSON`）作为 Python 命令行参数传递。当 agent 列表较大时，组合参数长度超过操作系统 `ARG_MAX` 限制，触发 `E2BIG`（Argument list too long）。

**代码证据**（`dispatch.sh:69-84`）：

```bash
# 69-75: 从配置文件提取具备 linyaps_packaging 能力的 agent（此处无问题，$CONFIG_FILE 是文件路径）
AGENTS_JSON=$(python3 - "$CONFIG_FILE" <<'PY'
import json,sys
try:
 c=json.load(open(sys.argv[1])); print(json.dumps([a for a in c.get('assignment',{}).get('agents',[]) if 'linyaps_packaging' in a.get('capabilities',[])]))
except Exception: print('[]')
PY
)

# 76: 获取完整平台 agent 列表（可能非常大）
PLATFORM_JSON=$(multica agent list --output json 2>/dev/null) || { output_json "$(json_reason agent_list_failed)"; exit 0; }

# 77-84: 将两个 JSON 字符串作为 CLI 参数传递给 Python —— 此处触发 E2BIG
CANDIDATES=$(python3 - "$AGENTS_JSON" "$PLATFORM_JSON" <<'PY'
import json,sys
cfg=json.loads(sys.argv[1]); raw=json.loads(sys.argv[2]); agents=raw.get('agents',raw) if isinstance(raw,dict) else raw
byname={a.get('name'):a for a in agents}
for c in cfg:
 a=byname.get(c.get('name'))
 if a and isinstance(a.get('id'),str): print(json.dumps({'name':c.get('name',''),'id':a['id'],'status':a.get('status','unknown')}))
PY
)
```

`$PLATFORM_JSON` 是 `multica agent list --output json` 的完整输出，包含所有 agent 的全部字段（`avatar_url`、`conversation_starters`、`description`、`disabled_runtime_skills` 等）。当 agent 数量较多时，单个 JSON 字符串即可达到数十 KB，两个参数组合后超过 `ARG_MAX`（通常 128KB–2MB）。

**会话证据**：
- 评论 `01a07aed`（2026-09-07T08:13:09Z）："后续 packer 指派仍被 `linyaps-src-init-dispatch` 阻塞：脚本将完整 agent 列表作为 Python 命令行参数传递，触发 `Argument list too long`，因此尚未产生指派副作用。需要修复该 dispatcher 后重新执行指派。"

**修复方案**：将 JSON 数据通过临时文件传递，而非 CLI 参数：

```bash
TMP_AGENTS=$(mktemp); TMP_PLATFORM=$(mktemp)
printf '%s' "$AGENTS_JSON" > "$TMP_AGENTS"
printf '%s' "$PLATFORM_JSON" > "$TMP_PLATFORM"
CANDIDATES=$(python3 - "$TMP_AGENTS" "$TMP_PLATFORM" <<'PY'
import json,sys
cfg=json.load(open(sys.argv[1])); raw=json.load(open(sys.argv[2]))
# ... 其余逻辑不变
PY
)
rm -f "$TMP_AGENTS" "$TMP_PLATFORM"
```

或通过 stdin 管道传递，避免创建临时文件。

---

## 5. Git 状态证据

以下 Git 状态快照由会话中 `git -C /media/deepin/Data/linyaps-projects status --short --branch; git -C ... log -1 --oneline` 命令获取（会话 markdown 第 3425–3432 行）：

```
## master...origin/master
 M CI_ll_be.maartenbaert.simplescreenrecorder/linglong.yaml
 M CI_ll_net.sourceforge.lgames.lgeneral/linglong.yaml
 M CI_ll_net.sourceforge.minetest/linglong.yaml
 M CI_ll_org.shotcut.shotcut/scripts/extract_appimage.sh
?? .linyaps-locks/.linyaps-build-net.sourceforge.minetest.lock/
?? CI_ll_net.sourceforge.minetest/net.sourceforge.minetest_5.8.0.40_x86_64_binary.layer
d6c319c7 feat: adapt com.sweethome3d source package
```

**分析**：

- HEAD 位于 `d6c319c7 feat: adapt com.sweethome3d source package`，确认 sweethome3d 源码适配最终成功提交。
- 工作区中 `CI_ll_com.sweethome3d/` 不出现在未提交变更中，说明该目录已干净入库。
- 未提交变更均来自其他项目（simplescreenrecorder、lgeneral、minetest、shotcut），与 sweethome3d 无关。
- `?? CI_ll_net.sourceforge.minetest/...binary.layer` 是未跟踪的 minetest 构建产物——正是 RC2 所述 guard 应阻止入库的缓存类型（新增暂存时阻断是正确的）。
- 注意：`CI_ll_alienblaster/alienblaster_1.1.0.0_x86_64_binary.layer` 不再出现在 git status 中，说明该文件已在 `9c680627` 提交中被删除入库（RC2 被绕过后完成）。

---

## 6. 结论

`com.sweethome3d`（LIN-3478）打包场景遭遇三重阻塞，分属三个独立根因：

1. **RC1（环境配置）**：`MULTICA_ISSUE_TASK_ID` 未导出，阻断初始化入口。此为平台触发任务时的环境注入缺失，非代码 bug。影响范围为所有同期触发的 issue（sweethome3d 和 kaffeine 均受影响）。在环境变量恢复后已自然解除。

2. **RC2（代码 Bug，核心）**：`pre-commit-guard.sh:59` 的 `git diff --cached --name-only --relative` 不区分暂存新增与暂存删除，导致 `clean_project_cache.sh` 删除已跟踪缓存文件后的删除记录被误判为"缓存被提交"而阻断。agent 通过手动方式绕过提交，但根因未修复——每次涉及已跟踪缓存文件删除的提交都会重复触发。**修复方案明确**：添加 `--diff-filter=d`。

3. **RC3（代码 Bug，次要）**：`dispatch.sh:77` 将完整 agent 列表 JSON 作为 Python CLI 参数传递，触发 `Argument list too long`。此 bug 阻断 packer 指派流程，导致构建产物无法流转。**修复方案明确**：改用临时文件或 stdin 传递 JSON。

**最终状态**：sweethome3d 源码适配已成功提交（`d6c319c7`），Ant 编译 `BUILD SUCCESSFUL`，但运行时输出检查失败（`/opt/apps/com.sweethome3d/files/bin/sweethome3d: No such file or directory`）——此为应用层打包配置问题（启动器路径或安装路径不匹配），非工作流基础设施 bug，不在本次分析范围内。

---

## 7. 修复优先级表

| 优先级 | 问题 | 根因类型 | 修复位置 | 修复方案 | 影响范围 |
|---|---|---|---|---|---|
| **P0** | pre-commit guard 阻断缓存删除暂存 | 代码 Bug | `pre-commit-guard.sh:59` | `git diff --cached --name-only` → `git diff --cached --name-only --diff-filter=d` | 所有涉及已跟踪缓存文件删除的提交 |
| **P1** | `MULTICA_ISSUE_TASK_ID` 未导出 | 环境配置 | 平台任务触发配置 | 确保任务触发时注入 `MULTICA_ISSUE_TASK_ID`（小写 UUID） | 所有初始化流程入口 |
| **P2** | dispatch 参数过长 | 代码 Bug | `dispatch.sh:77-84` | JSON 数据改用临时文件或 stdin 传递，不作为 CLI 参数 | 所有 packer 指派（agent 列表较大时） |
| **P3** | guard 匹配模式可更精确 | 设计改进 | `pre-commit-guard.sh:47` | `DEFAULT_PATTERN` 可限定更深路径前缀，减少误匹配概率 | guard 精度（当前已通过 `--diff-filter=d` 解决核心问题） |

---

## 8. 涉及源文件表

| 文件路径 | 关键行 | 角色 |
|---|---|---|
| `skills/linyaps-git-workflow/scripts/pre-commit-guard.sh` | 47, 59, 67, 73 | RC2 Bug 所在：guard 不区分暂存新增/删除 |
| `skills/linyaps-git-workflow/scripts/git-workflow.sh` | 157-159, 167, 171 | RC2 触发链：clean → add → guard 调用 |
| `skills/linyaps-git-workflow/scripts/clean_project_cache.sh` | 76-90, 100 | RC2 触发链：`remove_glob "*.layer"` 删除已跟踪缓存 |
| `skills/linyaps-src-init-dispatch/scripts/dispatch.sh` | 57-62, 69-84 | RC1 检查点 + RC3 Bug 所在：`get_issue_id()` 与 agent 列表 CLI 参数传递 |

> 注：会话中实际安装的 skill 路径为 `.omp/skills/linyaps-multica-packer-dispatch/scripts/dispatch.sh`（packer 节点用），而评论 `01a07aed` 提及的阻断脚本为 `linyaps-src-init-dispatch`（源码初始化节点用）。两者共享相同的 dispatch 逻辑结构，RC3 修复应同时覆盖两个 skill 的 `dispatch.sh`。
