# dispatch 动作字段声明（权威）

本文件是 `for-multica/agent.md` 调用 `linyaps-src-init-dispatch` 各动作时所用字段声明的**唯一权威源**。agent.md 通过 `skill({ name: "src2linyaps.constraints" })` 载入本 constraints SKILL 时一并获得本 references，不在 agent.md 正文内联字段声明代码块。

任务身份一律来自环境变量 `MULTICA_ISSUE_TASK_ID`（Step 1 解析校验）；`--issue-id` 仅作一致性校验，不作为主来源。CLI 参数经 `dispatch.sh` 统一解析。

## `dispatch_init`

按项目类型（binary/source）指派 init agent。**不接收 `--type` 参数**——类型由脚本内部检测 `$PROJECT_DIR/pak_linyaps.sh` 存在性得出（存在→binary，不存在→source）。

```
  action: "dispatch_init",
  issue_id: "$MULTICA_ISSUE_TASK_ID",
  pkgName: "<package_id>",
  project_dir: "CI_ll_<package_id>",
  arch: "<arch>",
  workflow_type: "debian-rules-to-linyaps",
  data_dir: "<data_dir>",
  workspace: "<workspace>",
  agent_config_path: "<agent_config_path>"
```

必填：`pkgName`、`project_dir`、`arch`、`workspace`、`agent_config_path`；可选：`workflow_type`、`data_dir`。

## `assign_packer`

Git 提交成功后，向 `linyaps-packer-*` 智能体发起打包指派。

```
  action: "assign_packer",
  issue_id: "$MULTICA_ISSUE_TASK_ID",
  pkgName: "<package_id>",
  project_dir: "CI_ll_<package_id>",
  arch: "<arch>",
  workflow_type: "debian-rules-to-linyaps",
  data_dir: "<data_dir>",
  workspace: "<workspace>",
  agent_config_path: "<agent_config_path>"
```

必填：`pkgName`、`project_dir`、`arch`、`workspace`、`agent_config_path`；可选：`workflow_type`、`data_dir`。Path B 使用 `workflow_type: "debian-rules-to-linyaps-fallback"`。

## `update_issue_status`

所有任务执行完毕后，根据统计更新 multica issue 状态。

```
  action: "update_issue_status",
  issue_id: "$MULTICA_ISSUE_TASK_ID",
  success_count: <成功数>,
  fail_count: <失败数>,
  workspace: "<workspace>",
  agent_config_path: "<agent_config_path>"
```

必填：`success_count`、`fail_count`；可选：`workspace`、`agent_config_path`。`issue_id` 由环境变量 `MULTICA_ISSUE_TASK_ID` 提供（非 CLI 参数）。
