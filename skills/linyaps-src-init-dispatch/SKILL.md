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

**输入**：
```json
{
  "action": "assign_packer",
  "pkgName": "kate",
  "project_dir": "CI_ll_kate",
  "arch": "x86_64",
  "workflow_type": "debian-rules-to-linyaps",
  "data_dir": "./data/2026-07-09.log",
  "workspace": "linyaps",
  "agent_config_path": "/path/to/for-multica/agent-config.json"
}
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
1. 从 `agent-config.json` 的 `assignment.agents[]` 筛选 capabilities 包含 `linyaps_packaging` 的 agent
2. **状态检查（热备方案）**：对每个候选 agent 执行 `scripts/check-agent-status.sh`：
   - `idle` → 记录"目标空闲，可立即指派"
   - `busy` → 记录警告"目标繁忙，仍发起指派（由平台排队）"，**不阻断**
   - 脚本报错 → 记录警告"无法查询状态，直接发起指派"，**不阻断**
3. **选择最佳节点**：优先 `idle`，全部 `busy` 则随机选一个
4. **指派执行**：查询当前 issue ID，通过 `multica issue comment add` 发送 `@mention` 评论，再通过 `multica issue assign` 将 issue 指派给目标 agent：
   ```
   @<packer_name> 请按照 <workflow_type> 流程执行 <project_dir> 打包任务（<arch>）
   ```
5. **记录指派日志**：写入 `data_dir/assignment.log`：
   ```
   assigned_packer, <pkgName>, <packer_name>, <arch>, <timestamp>
   ```
6. multica CLI 不可用或查询不到 ISSUE_ID → 记录警告，**不阻断**

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
