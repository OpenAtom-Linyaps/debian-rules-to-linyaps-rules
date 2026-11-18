---
name: linyaps-src-init-dispatch
description: >
  【debian-rules-to-linyaps / src init 节点】指派分发 SKILL。
  由 debian-rules-to-linyaps (src init) agent 在打包流程中调用，用于：
  (1) assign_packer — Git 提交成功后向 linyaps-packer 发起指派；
  (2) update_issue_status — 汇总后更新 issue 状态；
  (3) check_agent_status — 查询单个 agent 实时状态。
  不适用于其他节点类型。
argument-hint: '<action> <params>'
user-invocable: false
---

# linyaps-src-init-dispatch — 指派分发 SKILL

由 `debian-rules-to-linyaps` agent 在处理流程中调用，负责 multica 平台上与智能体指派相关的操作。

## 目录约定

- 共享脚本：`scripts/dispatch.sh`（统一入口）
- 配置来源：`agent_config_path` 参数指向的 `agent-config.json` 的 `assignment` 区段
- 本 skill 脚本：`skills/linyaps-src-init-dispatch/scripts/`

## 三种 Action 接口

### Action 1: `assign_packer`

Git 提交成功后，向 `linyaps-packer-*` 智能体发起打包指派。

**调用时机**：Step A6/B4 中 Git 提交成功后

**输入（assign_packer）**：`pkgName`、`project_dir`、`arch`、`workspace`、`agent_config_path` 必填；任务身份必须来自环境变量 `MULTICA_ISSUE_TASK_ID`，可用 `--issue-id` 仅作一致性校验。

任务 ID 和平台 agent ID 必须是完整小写 UUID。配置中的 agent name 仅用于查询和显示；运行时从 `multica agent list --output json` 获取真实 UUID。
```

**输出**：
```json
{
  "assigned": true,
  "target_agent": "linyaps-packer-1",
  "timestamp": "2026-07-09 10:30:00",
  "agent_status": "idle"
}
```

**执行逻辑**：
1. 显式校验 config、workspace、任务 UUID 和 CLI，失败输出 `blocked_reason`，不产生平台副作用。
2. 按配置顺序筛选 `linyaps_packaging`，以名称查询平台 agent，拒绝非 UUID。
3. `idle` 优先；`busy`、`running`、未知或状态查询失败均保留为可排队候选；无 idle 时选择配置顺序首个合法候选。
4. 先评论后指派；评论失败不执行指派。指派失败不写成功日志。
5. 评论和指派使用同一任务 UUID，指派使用 `--to-id <agent-uuid>`，mention 使用 `mention://agent/<agent-uuid>`。
### Action 2: `update_issue_status`

所有任务执行完毕后，根据统计更新 multica issue 状态。

**调用时机**：所有任务完成后的最终步骤

**输入**：
```json
{
  "action": "update_issue_status",
  "success_count": 8,
  "fail_count": 1,
  "workspace": "linyaps",
  "agent_config_path": "/path/to/for-multica/agent-config.json"
}
```

**输出**：
```json
{
  "issue_status": "审查完成",
  "comment_id": "comment-xxx"
}
```

**执行逻辑**：
1. 根据统计判断 issue 状态：
   - 全部成功（`fail_count=0`）→ `"审查完成"`
   - 部分失败 → `"部分完成"`
   - 全部失败 → `"阻塞"`
2. 通过 `multica issue comment add` 发送状态评论

### Action 3: `check_agent_status`

查询指定 agent 的实时状态（封装 `check-agent-status.sh`）。

**调用时机**：Packer 指派前

**输入**：
```json
{
  "action": "check_agent_status",
  "agent_name": "linyaps-packer-1",
  "workspace": "linyaps",
  "agent_config_path": "/path/to/for-multica/agent-config.json"
}
```

**输出**：
```json
{
  "agent_name": "linyaps-packer-1",
  "agent_id": "agent-xxx",
  "status": "idle",
  "running_tasks": []
}
```

## 指派目标配置

定义在 `agent_config_path` 指向的 `agent-config.json` 的 `assignment` 区段，本 skill **只读读取**，不自持配置。

### `assignment.agents[]`

| agent id | capabilities | 触发条件 |
|----------|-------------|---------|
| `linyaps-packer-1` | `linyaps_packaging` | 每个任务 Git 提交成功后 |
| `linyaps-packer-2` | `linyaps_packaging` | 每个任务 Git 提交成功后（热备） |

> **packer 本地检出目录**：packer 侧构建时读取**自己的** `agent-config.json` 中
> `global.pack_repo_dir` 作为本地检出目录。`dispatch.sh` 不改，指派消息不携带该路径
> （消息仅携带 `project_dir`/`arch`/`workflow_type`）。

### `assignment.default_strategy`

| 场景 | handler | 说明 |
|------|---------|------|
| 项目未找到 | `mark-failed` | 当前 agent 即为项目初始化者，不派发 |
| Skill 执行失败 | `mark-failed` | 直接标记失败，记录失败阶段 |
| 校验失败 | `mark-failed` | 不转交给其他智能体重试 |

## 约束

1. **仅 debian-rules-to-linyaps agent 调用**：此 skill 不应被其他 agent 使用
2. **与 agent_config_path 指向的 agent-config.json 的 assignment 区段绑定**：目标 agent 列表从配置读取
3. **`check_endpoint` 冷备未上线**：当前使用 `check-agent-status.sh` 脚本作为热备方案；后续上线后改由端点查询

## 精确 UUID 约束

任务唯一身份是导出的 `MULTICA_ISSUE_TASK_ID` 小写 UUID。缺失、非法或与 `--issue-id` 不一致时 blocked；禁止从 issue 列表、数字标识、历史评论、目录或 agent 名称推断。配置名称不作为 assign 身份，平台返回的 agent UUID 才是唯一 assign 身份。

输出必须包含 `target_agent_uuid`、`agent_status` 和 `blocked_reason`；异常不得产生 comment、assign 或成功 assignment 日志副作用。

实现参考：`scripts/dispatch.sh` 的 `get_issue_id()`、`is_uuid()` 与 `assign_packer` 的 `--to-id` 指派逻辑。
