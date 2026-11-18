# Issue-69 Agent/Skills 修复方案

## 1. 问题概述

Issue-69 暴露出 agent 与 dispatch skill 的运行时契约不一致：

- dispatch 脚本只允许 `idle` agent，`busy`/`running` 会被错误阻断。
- 状态查询失败会直接阻断，无法实现 Multica 排队语义。
- agent 配置缺少 `src_project_init` 能力对应的源码初始化 agent。
- 配置和脚本入口依赖相对路径，运行目录变化时可能出现 `Path not found`。
- 配置和 agent 文档仍强制使用 `${tag}` 与日期生成路径。
- 既有测试只覆盖 UUID 身份门控，没有覆盖配置路径和外部 cwd 场景。

## 2. 修复目标

1. 统一 dispatch 的 agent 选择语义：`idle` 优先，忙碌或状态未知时仍可确定性排队。
2. 保持任务 UUID 由 handoff 注入，禁止从 issue 列表或名称推断身份。
3. 统一配置入口和路径解析规则，避免依赖当前工作目录。
4. 移除 `${tag}`/日期路径的运行时强制依赖。
5. 补齐源码包初始化能力，并扩展行为验证。

## 3. 实施内容

### 3.1 Dispatch 状态选择

文件：`for-multica/skills/linyaps-binary-init-dispatch/scripts/dispatch.sh`

- 遍历配置中具备 `linyaps_packaging` capability 的候选 agent。
- 通过 `multica agent list --output json` 获取真实 agent UUID。
- 校验真实 UUID 为完整小写 UUID。
- `idle` agent 立即优先选中。
- `busy`/`running` agent 保留为候选，不再返回 `blocked`。
- 状态查询失败时记录 warning，并将状态记为 `unknown`，继续选择。
- 没有 idle agent 时，按配置顺序选择第一个合法候选。
- 输出中的 `agent_status` 反映实际选择时的状态。
- 仍严格保持 comment 后 assign，assign 使用 `--to-id`。
- comment 或 assign 失败时不写入 assignment 日志。

### 3.2 UUID 身份契约

- 唯一身份来源为 `MULTICA_ISSUE_TASK_ID`。
- 缺失或非法 UUID 时立即返回结构化 blocked 错误。
- 禁止使用 issue list 首项、数字 issue、历史评论、workspace 推断身份。
- 所有 comment、assign、status 操作均绑定同一任务 UUID。

### 3.3 配置和路径入口

文件：`for-multica/skills/linyaps-binary-init-dispatch/scripts/dispatch.sh`

- `--config` 必须显式提供且指向存在的文件。
- 脚本将 config canonicalize 为绝对路径。
- dispatch action 必须提供 workspace；status action 可不提供 workspace。
- 运行时入口应解析并校验 `WORKSPACE_ROOT`、`agent_config_path`、`skills_root` 和 workspace。
- skill/script 调用应使用绝对路径或基于脚本自身目录解析，禁止依赖 cwd。

### 3.4 配置能力补齐

文件：`for-multica/agent-config.json`

新增：

- `linyaps-src-init-1`
- capability：`src_project_init`

同时移除 active global 配置中的 `${tag}` 路径：

- `output_dir`：`./output`
- `data_dir`：`./data/dispatch.log`

### 3.5 文档契约同步

文件：

- `for-multica/skills/linyaps-binary-init-dispatch/SKILL.md`
- `for-multica/agent.md`
- `agents/deb-linglong-packer.agent.md`

同步内容：

- 明确 idle 优先、busy/running 可继续、查询失败可继续。
- 明确配置必须由调用方显式传入。
- 明确运行时使用已解析的绝对路径。
- 禁止未解析 `${tag}` 和日期生成路径。
- 保留 UUID-only 身份及 `--to-id` 精确指派约束。

## 4. 验证方案

### 4.1 自动验证

执行：

```bash
python3 -m json.tool for-multica/agent-config.json
bash -n tests/test_dispatch_uuid.sh
bash -n for-multica/skills/linyaps-binary-init-dispatch/scripts/dispatch.sh
bash tests/test_dispatch_uuid.sh
```

结果：全部通过。

### 4.2 测试覆盖

`tests/test_dispatch_uuid.sh` 现覆盖：

- 缺失 `MULTICA_ISSUE_TASK_ID` 必须 blocked。
- 非法 UUID 必须 blocked。
- 合法 UUID 的 status 更新必须绑定同一 issue UUID。
- 缺失 config 必须返回 `config_required`。
- 配置不得包含 `${tag}`。
- 从仓库外部 cwd 使用绝对 config 执行 status action 必须成功。

### 4.3 已知验证边界

当前测试脚本完整验证 UUID、配置和外部 cwd；busy/running 选择和状态查询失败场景已在 dispatch 实现中统一处理，但现有临时 mock 未提供完整 `check-agent-status.sh` 平台响应，因此未在该测试脚本中模拟完整 agent 状态 API。

## 5. 结果

修复后，dispatch 语义与 Multica 排队契约一致：空闲 agent 优先；无空闲 agent 时仍可向合法候选确定性排队；状态查询不再因 busy 或查询失败而错误阻断。配置、身份和路径入口也已收敛，源码包初始化 capability 已补齐。