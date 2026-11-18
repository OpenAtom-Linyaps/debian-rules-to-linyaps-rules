---
name: linyaps-git-workflow
description: >
  【debian-rules-to-linyaps / Multica 平台】Git 工作流 SKILL。
  负责 Git 仓库初始化（clone + 推送验证）和提交推送（commit + push）。
  由 debian-rules-to-linyaps agent 在打包流程中调用。
argument-hint: '<action> <params>'
user-invocable: false
---

# linyaps-git-workflow — Git 工作流 SKILL

由 `debian-rules-to-linyaps` agent 在处理流程中调用，负责 Git 仓库的初始化和提交推送操作。

## 目录约定

- 入口脚本：`scripts/git-workflow.sh`（统一入口）
- 配置来源：`agent_config_path` 参数指向的 `agent-config.json` 的 `global` 区段
- 本 skill 脚本：`skills/linyaps-git-workflow/scripts/`

## 两种 Action 接口

### Action 1: `init_repo`

Git 仓库克隆 + 推送权限验证。

**调用时机**：步骤 1（配置载入后立即执行）

**输入**：
```json
{
  "action": "init_repo",
  "projects_repo": "https://git.example.com/projects.git",
  "init_repo_dir": "./projects/init",
  "agent_config_path": "/path/to/for-multica/agent-config.json"
}
```

**输出**：
```json
{
  "status": "ready",
  "error": ""
}
```
- `status`：`"ready"`（成功）、`"blocked"`（失败）

**执行逻辑**：
1. 检查 `projects_repo` 是否为空 → 空则返回 `status: "blocked"`，记录 `git_repo_not_configured`
2. 若 `init_repo_dir` 为空 → 设定 `init_repo_dir=./projects/init`
3. 执行 `git clone <projects_repo> <init_repo_dir> 2>&1` → 失败则返回 `status: "blocked"`，记录 `git_clone_failed`
   - 若 `init_repo_dir` 已存在且为 git 仓库，改调用 `sync_upstream` 同步而非重新 clone；失败返回 `status: "blocked"`，记录 `git_sync_failed`
4. 切换到 `init_repo_dir`，执行 `git push --dry-run 2>&1` → 失败则返回 `status: "blocked"`，记录 `git_permission_denied`
5. 全部通过 → 返回 `status: "ready"`，记录 `git_ready`

### Action 2: `commit_and_push`

清理工程目录、Git 暂存、动态生成 commit message、推送。

**调用时机**：Step A6/B4（工程校验通过后）

**输入**：
```json
{
  "action": "commit_and_push",
  "init_repo_dir": "./projects/init",
  "data_dir": "./data/2026-07-09.log",
  "agent_config_path": "/path/to/for-multica/agent-config.json"
}
```

**输出**：
```json
{
  "committed": true,
  "commit_sha": "abc123...",
  "packages": ["kate", "kwrite"]
}
```
- `committed`：`true`（成功）、`false`（失败或无变更）

**执行逻辑**：
1. **切换目录**：切换到 `init_repo_dir`
2. **清理构建缓存**：对每个 `CI_ll_*` 工程目录调用 `scripts/clean_project_cache.sh <proj_dir>`（清理 `linglong/`、`bins/`、`reports/`、`build_cache/`、`*.layer`、`*.uab`、下载的原始套件文件等），只保留工程最小必要文件（`linglong.yaml`、`config/`）
3. **与上游同步（sync_upstream）**：`git fetch origin` → 若本地落后远程，则仅当存在本地改动（含未跟踪文件）时 `git stash push -u` → `git rebase`（不用 `--autostash`）→ 仅当确已 stash 且 stash 仍存在时才 `git stash pop`，保证本地与上游保持一致后再提交
   - rebase 冲突 → 中止 rebase，返回 `blocked:rebase_conflict`，**不 push**且本地改动保留在 stash
   - stash pop 冲突 → 返回 `blocked:stash_conflict`（改动保留工作区，交人工处理），**不 push**
   - 本地已最新或 fetch 失败 → 跳过同步，继续流程
4. **`git add .`**
5. **pre-commit 守卫**：调用 `scripts/pre-commit-guard.sh <init_repo_dir>`，命中缓存模式（`*.layer`、`*.uab`、`linglong/`、`bins/`、`reports/`、`build_cache/`、`.linyaps-locks/`）即退出码 1 → **阻断提交**，返回 `committed:false, blocked:pre_commit_guard`
6. **`git diff --cached --name-only`** 列出暂存文件
7. **动态生成 commit message**：
   - 仅新增包 → `feat: add debian-rules analysis for <package_id>`
   - 仅修改包 → `fix: update debian-rules analysis for <package_id>`
   - 多个包 → `feat: add/update multiple packages`
   - 无 CI_ll_ 变更 → `chore: update analysis scripts`
8. **`git commit`**：若无变更，记录已存在，不中断
9. **`git push`**：失败则记录 `git_push_failed`
10. **记录结果**到 `data_dir`：`git_commit_success, <commit_sha>` 或 `git_push_failed, <error>`

## 提交前缓存清理

任何 git commit/push 之前必须清理 `CI_ll_*` 工程目录内的构建缓存与下载产物，
避免 `*.layer`、`linglong/`、`bins/`、`reports/`、`.linyaps-locks/` 等缓存被意外
推送到仓库。`commit_and_push` 已自动调用以下两个脚本，也可手动执行：

```bash
# 清理指定工程目录缓存（--dry-run 预览，不实际删除）
"${skill_root}/scripts/clean_project_cache.sh" <project_dir> [--dry-run]

# 提交前守卫（git add 后调用，命中缓存即退出码 1 阻断提交）
"${skill_root}/scripts/pre-commit-guard.sh" <project_dir> [--ignore-patterns=<regex>]
```

### 清理内容

在指定的 `<project_dir>` 内删除：

- 核心构建缓存：`linglong/`、`bins/`、`reports/`、`build_cache/`、`file_res/`、
  `*.layer`、`*.uab`
- 下载产物：`*.deb`、`*.tar.gz|bz2|xz|zst`、`*.tgz`、`*.zip`
  - `src/`、`source/` 仅在确认为下载/解压缓存时删除（以该层级是否存在已被
    git 跟踪的工程源文件判断，绝不删除真实源码）

保留：`linglong.yaml`、`config/`、`scripts/`、`templates/`。

### pre-commit 守卫

`pre-commit-guard.sh` 在 `git add .` 后检查指定目录暂存列表，命中以下模式即
退出码 1（阻断提交）：`*.layer`、`*.uab`、`/linglong/`、`/bins/`、`/reports/`、
`/build_cache/`、`.linyaps-locks/`。可用 `--ignore-patterns=<regex>` 覆盖默认模式。

### 兜底检查（Fallback，由 LLM 执行）

确定性脚本无法覆盖全部场景（未知格式、新产生的缓存类型、脚本误留物等），
因此提交前追加一步由 LLM 判断的兜底扫描。请按以下步骤执行：

1. 用 `du` 扫描当前 session 对应的工程目录，定位可疑的大文件 / 大目录：
   ```bash
   # 各一级子目录体积（大到小）
   du -h --max-depth=1 <project_dir> | sort -h
   # 大文件（含深层，仅统计普通文件）
   find <project_dir> -type f -size +50M -exec du -h {} + | sort -h
   ```
2. 依据扫描结果识别可疑项，可疑特征包括：
   - 体积异常的缓存目录：`linglong/`、`bins/`、`reports/`、`build_cache/`、
     `file_res/`、`src/`、`source/`（未被 git 跟踪时的下载/解压物）
   - 大体积归档/产物：`*.layer`、`*.uab`、`*.deb`、`*.tar.*`、`*.tgz`、`*.zip`，
     以及任何体积 >100M 且不属于必要源文件的文件
   - 未被 `.gitignore` / `clean_project_cache.sh` 覆盖的新增缓存类型
3. 由 LLM 判断并执行：对确认的可疑项调用 `clean_project_cache.sh <project_dir>`；
   对脚本未覆盖的新增缓存，直接 `rm -rf` 前先在目录内确认它不是源码/必要文件，
   并可通过 `git ls-files --error-unmatch -- <path>` 确认是否被 git 跟踪
   （已跟踪则绝不删除）。
4. 兜底清理后再次运行 `pre-commit-guard.sh <project_dir>` 确认无残留缓存暂存。

## 约束

1. **仅 debian-rules-to-linyaps agent 调用**
2. **与 agent_config_path 指向的 agent-config.json 的 global.projects_repo / global.init_repo_dir 绑定**
3. **操作 git 仓库前必须先与上游同步**：`commit_and_push` 在 `git add` 前、`init_repo` 对已存在克隆均须先 `fetch` 并在本地落后时执行 `（仅在有本地改动时）stash -u + rebase +（仅当 stash 存在时）stash pop`，去掉 `--autostash`；rebase/stash 冲突返回阻塞状态，禁止强行 push
4. push 失败视为阻塞性错误，与初始化失败同等处理
5. **提交内容限制（强制）**：构建缓存与构建产物（含但不限于 `linglong/`、
   `bins/`、`reports/`、`build_cache/`、`file_res/`、`*.layer`、`*.uab`，以及下载的
   原始套件 `*.deb`/`*.tar.*`/`*.tgz`/`*.zip` 等）一律**禁止** `git add` 加入提交。
   提交前必须先执行 `clean_project_cache.sh`，再以 `pre-commit-guard.sh` 确认暂存区
   无任何缓存内容，通过后方可 `git commit`