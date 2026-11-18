# RC2+RC3 Agent/Skills 整改计划

## 问题

`examples/01a07d04_analyz.md` 分析了 `com.sweethome3d`（LIN-3478）打包场景的三重阻塞（RC1/RC2/RC3）。经当前仓库逐行核查：

- **RC1**（`MULTICA_ISSUE_TASK_ID` 未导出）是平台环境配置问题，非代码 bug，本仓库无可修改项。
- **RC2**（pre-commit guard 误阻缓存删除暂存）**确认存在于当前仓库**：`skills/linyaps-git-workflow/scripts/pre-commit-guard.sh:59` 的 `git diff --cached --name-only --relative` 缺少 `--diff-filter=d`，已跟踪缓存文件被 `clean_project_cache.sh` 删除后，删除记录仍命中 `.layer$` 模式，阻断所有涉及已跟踪缓存删除的提交。
- **RC3**（dispatch 参数过长）**确认存在于当前仓库**：`skills/linyaps-src-init-dispatch/scripts/dispatch.sh` 第 77 行（`assign_packer` action 内）将 `$AGENTS_JSON` 和 `$PLATFORM_JSON` 作为 Python CLI 参数传递（`python3 - "$AGENTS_JSON" "$PLATFORM_JSON"`），agent 列表较大时触发 `E2BIG`。
- 分析第 322 行提到 packer 节点有另一份 `linyaps-multica-packer-dispatch` skill。当前仓库 **不存在** 此 skill（`for-multica/scripts/` 为空目录，`skills/` 下无对应目录），RC3 仅需修复 `linyaps-src-init-dispatch` 一处。

目标：修复 RC2 和 RC3 两个代码 bug，新增回归测试，使涉及已跟踪缓存删除的提交不再被误阻、packer 指派不再因 `ARG_MAX` 失败。执行前先将本实施方案导出到 `docs/` 留档。

## 改动的文件清单

|#|文件|改动类型|
|---|---|---|
|1|`skills/linyaps-git-workflow/scripts/pre-commit-guard.sh`|修改第 59 行：`git diff` 添加 `--diff-filter=d`|
|2|`skills/linyaps-src-init-dispatch/scripts/dispatch.sh`|修改第 77-84 行：`assign_packer` 的 CANDIDATES 提取改用 stdin|
|3|`tests/test_rc2_pre_commit_guard.py`|新建：RC2 回归测试|
|4|`tests/test_issue62.py`|追加：RC3 大 agent 列表回归测试|

### 0. 导出实施方案到 `docs/`

将本计划内容复制到 `docs/rc2-rc3-skills-repair-plan.md`（`docs/` 目录已存在、当前为空）。此步骤在所有代码改动之前执行，作为执行前留档。内容与本计划 `local://rc2-rc3-skills-repair-plan.md` 完全一致。

## 各文件具体改动

### 1. `skills/linyaps-git-workflow/scripts/pre-commit-guard.sh`

**第 59 行**：

当前：
```bash
CACHED_FILES=$(git diff --cached --name-only --relative 2>/dev/null || true)
```

改为：
```bash
CACHED_FILES=$(git diff --cached --name-only --diff-filter=d --relative 2>/dev/null || true)
```

`--diff-filter=d`（小写 d = exclude Deleted）使 `git diff` 仅列出 Added/Modified/Copied/Renamed 等非删除暂存路径。guard 的设计意图是阻止"缓存文件被新增暂存"，此修复使删除已跟踪缓存文件（`clean_project_cache.sh` 的正确行为）不再被误判为"缓存被提交"。

无其他 callsite 需修改：`git-workflow.sh:171` 调用 `pre_commit_guard()` 函数，函数内部转发到 `pre-commit-guard.sh`，无需改动。

### 2. `skills/linyaps-src-init-dispatch/scripts/dispatch.sh`

**第 77-84 行**（`assign_packer` action 内 CANDIDATES 提取）：

当前：
```bash
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

改为：
```bash
CANDIDATES=$(printf '%s\n%s\n' "$AGENTS_JSON" "$PLATFORM_JSON" | python3 - <<'PY'
import json,sys
lines=sys.stdin.read().split('\n',1)
cfg=json.loads(lines[0]); raw=json.loads(lines[1]); agents=raw.get('agents',raw) if isinstance(raw,dict) else raw
byname={a.get('name'):a for a in agents}
for c in cfg:
 a=byname.get(c.get('name'))
 if a and isinstance(a.get('id'),str): print(json.dumps({'name':c.get('name',''),'id':a['id'],'status':a.get('status','unknown')}))
PY
)
```

改动点：
- 不再通过 `sys.argv[1]`/`sys.argv[2]` 读取 JSON，改为从 stdin 读取两行（`AGENTS_JSON` 和 `PLATFORM_JSON` 以 `\n` 分隔）。
- 使用 `printf '%s\n%s\n'` 写入管道，不创建临时文件，无清理负担。
- Python 逻辑不变：从配置 agent 列表匹配平台 agent，输出 `{name, id, status}`。

### 3. `tests/test_rc2_pre_commit_guard.py`（新建）

测试场景：在临时 git 仓库中创建一个已跟踪的 `.layer` 文件，`git rm` 后 `git add .` 暂存删除，运行 `pre-commit-guard.sh`，断言退出码为 0（通过，不阻断）。

对照场景：创建一个新增的 `.layer` 文件并 `git add`，运行 guard，断言退出码为 1（阻断）——验证 guard 仍正确阻止缓存新增。

测试结构沿用 `tests/test_issue62.py` 的风格：`subprocess.run` + `tempfile.TemporaryDirectory` + 直接调用脚本路径。

关键断言：
- `test_deleted_tracked_layer_passes` — 删除已跟踪 `.layer` 暂存后 guard 退出码 0（修复后行为）
- `test_added_layer_blocked` — 新增 `.layer` 暂存后 guard 退出码 1（guard 核心功能不变）

### 4. `tests/test_issue62.py`（追加）

新增测试函数 `test_assign_packer_large_agent_list_no_arg_overflow`：
- 构造一个包含大量 agent 的 mock `multica agent list` 输出（每个 agent 的 JSON 对象约 2KB，生成 200 个 agent ≈ 400KB，远超典型 `ARG_MAX` 的单参数安全阈值）。
- 使用 `make_mock_multica` 的模式生成 mock 脚本，但 agent list 输出改为大体积 JSON。
- 运行 `dispatch.sh assign_packer`，断言 `returncode == 0` 且 stdout 中 `assigned` 为 `true`（或至少不因 `E2BIG` 崩溃）。
- 验证 dispatch.sh 源码不含 `json.loads(sys.argv[1])` 读取 JSON 的模式。

## 验证

### RC2 验证

```bash
cd /media/ut005422/Data-2/linyaps-project/ai-labs/repos.git/repo.gitlab/debian-rules-to-linyaps-rules
python3 -m pytest tests/test_rc2_pre_commit_guard.py -v
```

预期：
- `test_deleted_tracked_layer_passes` — 删除已跟踪 `.layer` 暂存后 guard 退出码 0（通过）
- `test_added_layer_blocked` — 新增 `.layer` 暂存后 guard 退出码 1（阻断）

### RC3 验证

```bash
python3 -m pytest tests/test_issue62.py -v
```

预期：所有现有测试 + 新增 `test_assign_packer_large_agent_list_no_arg_overflow` 全部通过。

### 语法检查

```bash
bash -n skills/linyaps-src-init-dispatch/scripts/dispatch.sh
bash -n skills/linyaps-git-workflow/scripts/pre-commit-guard.sh
```

## 假设与风险

- **`linyaps-multica-packer-dispatch` skill 不在当前仓库**：分析第 322 行提到 packer 节点有独立的 dispatch skill。经 `glob` 确认当前仓库 `for-multica/scripts/` 为空、`skills/` 下无该目录。若该 skill 部署在其他仓库或 `.omp/skills/` 运行时安装路径中，RC3 修复无法覆盖它——需要在该 skill 的源仓库中同步应用相同的 stdin 传递修复。本计划仅修复当前仓库内的 `linyaps-src-init-dispatch`。
- **RC1 不在代码修复范围**：`MULTICA_ISSUE_TASK_ID` 注入是平台运维职责，`dispatch.sh:57-62` 的 `get_issue_id()` 逻辑正确（优先读环境变量、fallback 到 `--issue-id` 参数并做一致性校验），无需改动。
- **`--diff-filter=d` 大小写**：Git 文档中 `--diff-filter=d`（小写 d）表示 exclude deleted。若实现时误用大写 `D`，则语义反转为"仅显示 deleted"——会导致所有非删除变更被跳过。实现时须用小写 `d`。
