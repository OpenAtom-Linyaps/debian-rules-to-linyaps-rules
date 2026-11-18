# Plan: src2linyaps.debug 构建验证 + 运行验证 + 条件 Git 推送

## 目标

修复 `src2linyaps.debug` 技能工作流缺陷：在 `validate-linglong-yaml.py` 校验通过后、指派 packer 之前，插入构建验证 + 运行验证 + 条件 Git 推送三个子阶段。参考模式来自 `examples/linyaps-packaging-scripts-running-skill-v3.2026.9.20.1.dev`。

## 修改文件

**唯一文件**：`skills/src2linyaps.debug/SKILL.md`

## 当前状态分析

### 现有工作流（四阶段）

1. 阶段一：`ll-builder extract` 解压 layer
2. 阶段二：对照分析（只读）
3. 阶段三：修复（调用内部 skills + `validate-linglong-yaml.py`）
4. 阶段四：指派 packer

**缺陷**：
- 阶段三第102行：`修复落地提交 | linyaps-git-workflow | commit + push（若已绑定仓库）` — Git 推送列在修复表中，无构建/运行验证门控，无推送条件。
- `validate-linglong-yaml.py` 退出码 0 后直接进入阶段四，无构建验证、无运行验证。

### 关键约束

1. **当前仓库无 `monitor-build.sh` / `check-build-active.sh`**（仅存在于 `examples/` 参考示例中）。`skills/src2linyaps.debug/` 无 `scripts/` 目录，只有 `SKILL.md` 和 `ll-builder.command.reference.md`。
2. **`linyaps-git-workflow` 的 `commit_and_push`**（`git-workflow.sh:142-237`）：
   - 不支持 `--commit-message` 参数；commit message 由暂存文件中 `CI_ll_*` 包名动态生成。
   - 无 Git 评论/注释机制。
   - 输出 JSON：`{"committed":true/false,"commit_sha":"...","packages":[...]}`。
3. **参考构建约束**（`linyaps-packaging.constraints §2`）：`MAX_BUILD_ATTEMPTS=2`，`BUILD_TIMEOUT_SEC=1800`，退出码 124 时检查进程是否活跃。
4. **参考运行验证**（`bin2linyaps.compat-testing`）：`timeout 30 ll-builder run --build-dir <dir>`，退出码 0 或 124 = 通过，其他非零 = 失败。

## 设计决策

### 决策1：构建/运行验证的执行方式

**选择**：SKILL.md 中内联描述由 LLM 直接执行 `ll-builder build` / `ll-builder export` / `ll-builder run` 命令，重试和超时逻辑由 LLM 管理。

**理由**：
- 当前仓库无 `monitor-build.sh` / `check-build-active.sh`，且本次修改只能改 `SKILL.md` 一个文件。
- 参考示例中这些脚本属于 `linglong-source-updater` 的 `scripts/` 目录，不在当前仓库的 `skills/` 体系内。
- SKILL.md 的 `tools` 声明了 `execute: true`，LLM 有能力直接执行 `ll-builder` 命令并管理重试。
- 退出码 124 消歧：LLM 执行 `pgrep -x ll-builder || pgrep -x fuse-overlayfs || pgrep -x erofsfuse` 判断进程是否活跃（内联 `check-build-active.sh` 的核心逻辑）。

### 决策2：Git 警告评论机制

**选择**：成功 → 调用 `linyaps-git-workflow` 的 `commit_and_push` 正常推送。失败 → 先调用 `commit_and_push` 推送，再用 `multica issue comment add` 向 multica issue 追加警告评论。

**理由**：
- `commit_and_push` 不支持自定义 commit message，无法在 commit message 中嵌入警告。
- multica comment 是项目已有的 issue 评论机制：`linyaps-src-init-dispatch` 的 `dispatch.sh` 已在 `assign_packer`（第102行）和 `update_issue_status`（第128行）中使用 `multica issue comment add "$ISSUE_ID" --content "..."` 模式。
- 任务 ID 来自环境变量 `MULTICA_ISSUE_TASK_ID`（agent 定义中声明，所有子 skill 可用）。
- 失败时仍需推送（用户要求"运行失败 → 仍然推送"），所以先 `commit_and_push` 再追加 multica 警告评论。

**备选方案（不选）**：
- `git notes` → 需额外推送 `refs/notes/commits`，且不直观（需 `git log --show-notes` 才能查看）；multica comment 在 issue 页面直接可见。
- 手动 `git commit` 带警告后缀 → 绕过了 `commit_and_push` 的缓存清理、upstream 同步、pre-commit 守卫等安全机制。

### 决策3：阶段命名

将原四阶段扩展为五阶段：
- 阶段一：解压 layer（不变）
- 阶段二：对照分析（不变）
- 阶段三：修复 + 校验（不变，但删除第102行的 Git 推送行，移到新阶段）
- **阶段四（新）**：构建验证 + 运行验证 + 条件 Git 推送
- 阶段五：指派 packer（原阶段四，重新编号）

## 详细修改方案

### 修改0：导出实施方案到 `docs/`

在所有代码改动之前，将本实施方案复制到 `docs/src2linyaps-debug-build-run-verify-plan.md`（`docs/` 目录已存在）。此步骤作为执行前留档，内容与本计划 `local://src2linyaps-debug-build-run-verify-plan.md` 完全一致。命名遵循现有 `docs/` 约定（如 `rc2-rc3-skills-repair-plan.md`）。

### 修改1：阶段标题（第67行）

```diff
- ## 工作流程（四阶段）
+ ## 工作流程（五阶段）
```

### 修改2：修复表删除 Git 推送行（第102行）

删除修复表中的这一行：
```
| 修复落地提交 | `linyaps-git-workflow` | commit + push（若已绑定仓库） |
```

Git 推送移到新阶段四，受构建/运行验证门控。

### 修改3：校验通过后指向新阶段（第126行）

```diff
- 退出码 0 → 校验通过，继续阶段四
+ 退出码 0 → 校验通过，继续阶段四（构建验证 + 运行验证 + 条件 Git 推送）
```

### 修改4：新增阶段四（在阶段三结束后、原阶段四之前插入）

在 `阶段三` 结束（第127行后）和 `阶段四 · 指派 packer`（第129行）之间插入完整的阶段四内容：

```markdown
### 阶段四 · 构建验证 + 运行验证 + 条件 Git 推送

`validate-linglong-yaml.py` 校验通过后，先构建验证 + 运行验证，再根据结果决定 Git 推送方式。

#### 4.1 构建验证

在 `<project_path>` 目录下执行 `ll-builder build` + `ll-builder export`，重试 ≤ 2 次（含首次），单次超时窗口 1800 秒。

**构建命令**：
```bash
# 记录开始时间，用于后续 .layer 文件检测
start_time=$(date +%s)

# 构建尝试（最多 2 次）
for attempt in 1 2; do
  echo "== 构建尝试 $attempt/2 =="
  timeout 1800 ll-builder build --skip-output-check --build-dir <project_path>
  build_rc=$?

  # 退出码 124 = timeout 命令超时，需消歧
  if [[ $build_rc -eq 124 ]]; then
    # 检查构建进程是否仍活跃（等价于 check-build-active.sh）
    if pgrep -x ll-builder >/dev/null 2>&1 || pgrep -x fuse-overlayfs >/dev/null 2>&1 || pgrep -x erofsfuse >/dev/null 2>&1; then
      echo "== 构建仍在进行，继续等待 =="
      wait  # 等待已有进程完成
      build_rc=$?
    else
      echo "== 构建进程已退出（超时无活跃进程），判定挂起 =="
    fi
  fi

  if [[ $build_rc -eq 0 ]]; then
    echo "== 构建成功 =="
    break
  fi

  [[ $attempt -lt 2 ]] && sleep 10 && echo "== 重试构建 =="
done

# 构建失败则跳过导出，标记构建验证失败
if [[ $build_rc -ne 0 ]]; then
  build_verify="failed"
else
  # 导出 layer
  timeout 1800 ll-builder export --layer --no-develop -z zstd --build-dir <project_path>
  export_rc=$?

  # 退出码 124 消歧（同上）
  if [[ $export_rc -eq 124 ]]; then
    if pgrep -x ll-builder >/dev/null 2>&1 || pgrep -x fuse-overlayfs >/dev/null 2>&1 || pgrep -x erofsfuse >/dev/null 2>&1; then
      wait
      export_rc=$?
    fi
  fi

  if [[ $export_rc -eq 0 ]]; then
    # 检测本轮导出的 .layer 文件
    layer_file=$(find <project_path> -maxdepth 1 -name "*.layer" -type f -newermt "@$start_time" 2>/dev/null | head -1)
    if [[ -n "$layer_file" ]]; then
      build_verify="passed"
    else
      build_verify="failed"
    fi
  else
    build_verify="failed"
  fi
fi
```

**约束**：
- `--skip-output-check`：跳过输出检查（调试阶段允许非标准输出）。
- `--layer --no-develop -z zstd`：导出 layer 格式，不包含 develop 层，zstd 压缩。
- 退出码 124 时**不得仅凭超时判失败**：必须检查 `ll-builder` / `fuse-overlayfs` / `erofsfuse` 进程是否仍活跃。
- `.layer` 文件检测：仅取本轮构建开始后生成的（`-newermt "@$start_time"`）。

#### 4.2 运行验证

从导出的 layer 中执行应用 `command`，检查非正常退出。

**运行命令**：
```bash
if [[ "$build_verify" == "passed" ]]; then
  # 使用 ll-builder run 验证应用可正常启动
  timeout 30 ll-builder run --build-dir <project_path>
  run_rc=$?

  # 退出码 0 = 正常退出（通过）；124 = timeout 触发但进程可能仍在运行（视为通过）
  if [[ $run_rc -eq 0 || $run_rc -eq 124 ]]; then
    run_verify="passed"
  else
    run_verify="failed"
  fi
else
  run_verify="skipped"  # 构建失败时跳过运行验证
fi
```

**约束**：
- 超时 30 秒（应用启动验证，非完整功能测试）。
- 退出码 0 或 124 = 通过；其他非零退出码 = 失败。
- 构建验证失败时跳过运行验证（`run_verify="skipped"`）。

#### 4.3 条件 Git 推送

根据构建验证 + 运行验证结果决定推送方式。

**成功（`build_verify="passed"` 且 `run_verify="passed"`）**：
```bash
bash skills/linyaps-git-workflow/scripts/git-workflow.sh commit_and_push \
  --init_repo_dir=<repo_dir> [--data-dir=<data_dir>]
```
- 正常推送，`commit_and_push` 自动处理缓存清理、upstream 同步、pre-commit 守卫、动态 commit message 生成、commit、push。

**失败（`build_verify="failed"` 或 `run_verify="failed"`）**：
```bash
# 1. 先正常推送修复
push_output=$(bash skills/linyaps-git-workflow/scripts/git-workflow.sh commit_and_push \
  --init_repo_dir=<repo_dir> [--data-dir=<data_dir>])

# 2. 从 commit_and_push 输出 JSON 中解析 commit_sha
commit_sha=$(echo "$push_output" | jq -r '.commit_sha // empty')

# 3. 通过 multica comment 追加警告评论（任务 ID 来自环境变量 MULTICA_ISSUE_TASK_ID）
multica issue comment add "$MULTICA_ISSUE_TASK_ID" \
  --content "⚠️ build/run verification failed: build=$build_verify run=$run_verify (commit: $commit_sha)"
```

- 用 `multica issue comment add` 追加警告评论（项目已有机制，issue 页面直接可见）。
- 任务 ID 来自环境变量 `MULTICA_ISSUE_TASK_ID`，与 `linyaps-src-init-dispatch` 的 `assign_packer`/`update_issue_status` 使用同一模式。

```diff
- ### 阶段四 · 指派 packer（默认）
+ ### 阶段五 · 指派 packer（默认）
```

### 修改6：更新内部 skills 清单表（第62行）

更新 `linyaps-git-workflow` 行的用途描述，反映新的条件推送角色：

```diff
- | `linyaps-git-workflow` | `skills/linyaps-git-workflow/` | Git 提交/推送修复后的工程（可选，调试修正落地） |
+ | `linyaps-git-workflow` | `skills/linyaps-git-workflow/` | Git 提交/推送修复后的工程（阶段四条件推送） |
```

### 修改7：更新约束（第148-155行）

在约束列表中追加构建/运行验证相关约束：

```diff
  6. **`assign_packer` 需agent_config_path`**：用户未提供时，如需要指派则向用户确认 `agent_config_path`。
+ 7. **构建验证重试限制**：`ll-builder build` + `ll-builder export` 各最多 2 次尝试（含首次），超时 1800 秒/次。退出码 124 时必须检查 `ll-builder`/`fuse-overlayfs`/`erofsfuse` 进程活跃性，不得仅凭超时判失败。
+ 8. **运行验证超时**：`ll-builder run` 超时 30 秒；退出码 0/124 = 通过，其他非零 = 失败。
+ 9. **Git 推送条件性**：构建+运行验证通过 → 正常推送；验证失败 → 仍推送但通过 `multica issue comment add` 追加警告评论（任务 ID 来自 `MULTICA_ISSUE_TASK_ID`）。
```

### 修改8：更新输出（第157-165行）

在输出报告中追加构建/运行验证结果：

```diff
  修复报告：
  - 诊断问题（问题类型 + 定位 + 依据）
  - 调用的 skill
  - 改动 before/after
  - 补齐 common res 清单
  - 校验结果
+ - 构建验证结果（passed/failed + .layer 文件路径）
+ - 运行验证结果（passed/failed/skipped + 退出码）
+ - Git 推送结果（committed + commit_sha + 是否追加 multica 警告评论）
  - 指派结果 / 结束标记
```

### 修改9：更新目录约定（第31行）

修正不存在的 `scripts/` 目录引用：

```diff
- - 本 skill 脚本：`skills/src2linyaps.debug/scripts/`
+ - 本 skill 无独立 scripts 目录；构建/运行验证由 LLM 直接执行 `ll-builder` 命令。
```

## 验证检查清单

- [ ] 修改0：导出实施方案到 `docs/src2linyaps-debug-build-run-verify-plan.md`（代码改动前执行）

- [ ] 阶段标题从「四阶段」改为「五阶段」
- [ ] 修复表中删除 Git 推送行（第102行）
- [ ] 校验通过后指向「阶段四（构建验证 + 运行验证 + 条件 Git 推送）」
- [ ] 新增阶段四包含 4.1 构建验证、4.2 运行验证、4.3 条件 Git 推送
- [ ] 构建验证：`ll-builder build --skip-output-check` + `ll-builder export --layer --no-develop -z zstd`，重试 ≤ 2 次，超时 1800s，退出码 124 消歧
- [ ] 运行验证：`timeout 30 ll-builder run`，退出码 0/124 = 通过
- [ ] 条件推送：成功 → `commit_and_push`；失败 → `commit_and_push` + `multica issue comment add` 警告评论
- [ ] 原阶段四重编号为阶段五
- [ ] 更新内部 skills 清单表中 `linyaps-git-workflow` 用途
- [ ] 约束追加 7/8/9 三条
- [ ] 输出追加构建/运行/Git 推送结果
- [ ] 修正目录约定中不存在的 `scripts/` 引用
