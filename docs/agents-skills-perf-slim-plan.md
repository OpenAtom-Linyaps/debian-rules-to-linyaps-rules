# agents-skills-perf-slim-v2 — Agent/Skills 上下文效率精简方案（净减版）

> 本文件为 `local://agents-skills-perf-slim-v2-plan.md` 的导出留档，不影响运行逻辑。

> 前序方案 `agents-skills-perf-slim`（15 项改动）已应用于工作树，净增 **+4800 字符**（8 文件合计），违背"精简"目标。本方案撤销不利改动、保留有利改动，并追加冗余节删除，实现**净减约 7800 字符**（相对 HEAD）。

## Context

`debian-rules-to-linyaps` agent 及子 skill 负责 Debian→玲珑 `linglong.yaml` 转换。前序方案尝试通过注入"上下文效率（强制）"建议节 + 内联读取收敛来降低 context 开销，但建议节本身是元指令反模式——7 个建议节合计 ~4505 字符，仅重复内联编辑已强化的行为，导致净增。

**根因**：建议性"节省上下文"节本身就是上下文开销。真正的行为杠杆是内联指令（"传文件路径，不预读全文"），而非独立的建议节。

## Approach

三步：(1) 删除全部 7 个建议性节（撤销前序方案的不利改动）；(2) 保留 8 项内联收敛编辑（前序方案的有利改动，行为层面有效）；(3) 追加删除工作树中既有的冗余节（非前序方案引入，但可顺手精简）——`agent.md` 尾部 4 节与工作流步骤/约束/Skills 加载完全重复，`for-multica/agent.md` `## 约束` 节与 `agent.md` `## 约束条件` 逐字重复，`agent.md` `## 约束条件` 中 4 个子节与 `src2linyaps.constraints` SKILL.md 重复。最后 (4) 将本 v2 方案刷新到 `docs/agents-skills-perf-slim-plan.md`，替换原 v1 内容。

不改脚本行为，不改输入输出契约，不触碰受保护文件。

### 当前状态（工作树 vs HEAD）

| 文件 | 工作树 (chars) | HEAD (chars) | 当前增量 |
|------|---------------|-------------|---------|
| `agents/debian-rules-to-linyaps.agent.md` | 20842 | 19511 | +1331 |
| `for-multica/agent.md` | 22941 | 21293 | +1648 |
| `skills/src2linyaps.debian.analyze-control/SKILL.md` | 4604 | 4251 | +353 |
| `skills/src2linyaps.debian.analyze-rules/SKILL.md` | 5121 | 4768 | +353 |
| `skills/src2linyaps.debian.build-res-generate/SKILL.md` | 7883 | 7530 | +353 |
| `skills/src2linyaps.debian.test-deps/SKILL.md` | 2040 | 1687 | +353 |
| `skills/src2linyaps.debug/SKILL.md` | 9456 | 9531 | −75 |
| `for-multica/skills/linyaps-upstream-query/SKILL.md` | 3505 | 3021 | +484 |
| **合计** | **76392** | **71592** | **+4800** |

### 改动清单

#### A 组：删除建议性节（撤销前序方案不利改动，−4505 字符）

| # | 文件 | 行号（工作树当前） | 删除内容 | 删除字符 |
|---|------|-------------------|---------|---------|
| A1 | `agents/debian-rules-to-linyaps.agent.md` | L371–381（含 L381 空行） | `## 上下文效率（强制）` 节：标题 + 空行 + 说明行 + 空行 + 6 条编号规则 + 空行 | 1209 |
| A2 | `for-multica/agent.md` | L355–365（含 L365 空行） | `## 上下文效率（强制）` 节：标题 + 空行 + 说明行 + 空行 + 6 条编号规则 + 空行 | 1409 |
| A3 | `skills/src2linyaps.debian.analyze-control/SKILL.md` | L85–89（含 L84 空行 → 改为 L84 空行保留，删 L85–88 + 尾部） | `## ⚠️ 上下文效率` 节：空行 + 标题 + 空行 + 3 条要点 | 351 |
| A4 | `skills/src2linyaps.debian.analyze-rules/SKILL.md` | L103–107 | 同 A3 结构 | 351 |
| A5 | `skills/src2linyaps.debian.build-res-generate/SKILL.md` | L140–144 | 同 A3 结构 | 351 |
| A6 | `skills/src2linyaps.debian.test-deps/SKILL.md` | L51–55 | 同 A3 结构 | 351 |
| A7 | `for-multica/skills/linyaps-upstream-query/SKILL.md` | L72–76 | `## ⚠️ 上下文效率` 节：空行 + 标题 + 空行 + 3 条要点 | 483 |
| | | | **A 组小计** | **~4505** |

**精确删除边界**（每节含其前导空行到节末，确保删后上下节间仅保留一个空行分隔）：

- **A1** `agent.md`：删除 L371（`## 上下文效率（强制）`）至 L381（空行，`## 失败处理策略` 前）。L370 是 `## Phase 3` 末行（`3. **输出路径**...`），L370 后直接接 L382 `## 失败处理策略`，中间保留一个空行。
- **A2** `for-multica/agent.md`：删除 L355（`## 上下文效率（强制）`）至 L365（空行，`## 约束` 前）。L354 是代码块闭合 ```，L354 后直接接 L366 `## 约束`，中间保留一个空行。
- **A3** `analyze-control/SKILL.md`：删除 L84（空行）至 L89（文件末尾，如存在尾行）。L83 是 `## 约束` 末条，L83 后为文件结尾。实际：删除 L84 空行 + L85 标题 + L86 空行 + L87–89 三条要点。L83 后保留一个尾行空行或直接结束。
- **A4** `analyze-rules/SKILL.md`：同 A3 结构。删除 L102 空行 + L103 标题 + L104 空行 + L105–107 三条要点。
- **A5** `build-res-generate/SKILL.md`：同 A3 结构。删除 L139 空行 + L140 标题 + L141 空行 + L142–144 三条要点。
- **A6** `test-deps/SKILL.md`：同 A3 结构。删除 L50 空行 + L51 标题 + L52 空行 + L53–55 三条要点。
- **A7** `upstream-query/SKILL.md`：同 A3 结构。删除 L71 空行 + L72 标题 + L73 空行 + L74–76 三条要点。

#### B 组：保留内联收敛编辑（前序方案有利改动，不操作）

以下 8 项编辑已在工作树中，**不删除、不修改**：

| # | 文件 | 位置 | 内容 | 价值 |
|---|------|------|------|------|
| B1 | `agents/debian-rules-to-linyaps.agent.md` | L43–68 | 修复粘连 JSON 块（global/extension/assignment 三段完整示例） | 正确性 |
| B2 | `agents/debian-rules-to-linyaps.agent.md` | L192 | Fallback 行收敛（多行 `cat` 示例 → 单行通用约定） | 行为收敛，净负 |
| B3 | `agents/debian-rules-to-linyaps.agent.md` | L257 | A2 读取指令：`读取 debian/control 完整文本` → `init-control.py 直接接收文件路径参数，不预读 control 全文入 context` | 行为收敛 |
| B4 | `agents/debian-rules-to-linyaps.agent.md` | L277 | A3.2 读取指令：`读取 debian/rules 完整内容` → `读取 debian/rules 的 override 段；不重复读取 A3.1` | 行为收敛 |
| B5 | `skills/src2linyaps.debug/SKILL.md` | L76 | reference 单源（删除 `examples/ll-builder` 副本引用） | 行为收敛，净负 |
| B6 | `for-multica/agent.md` | L157 | Fallback 收敛：`读取 SKILL.md 并内联记录其约束` → `仅读取约束摘要，不内联全文` | 行为收敛 |
| B7 | `for-multica/agent.md` | L182 | 同 B3 | 行为收敛 |
| B8 | `for-multica/agent.md` | L195 | 同 B4 | 行为收敛 |

#### C 组：删除冗余节（工作树既有内容，非前序方案引入，−2793 字符）

| # | 文件 | 行号 | 删除内容 | 删除字符 | 冗余原因 |
|---|------|------|---------|---------|---------|
| C1 | `agents/debian-rules-to-linyaps.agent.md` | L407–434 | `## 输出格式` 节（kate 完整 YAML 示例，28 行） | 561 | 工作流 Phase 3 步骤 2 已描述输出路径；`generate-linglong-yaml.py` 保证输出格式 |
| C2 | `agents/debian-rules-to-linyaps.agent.md` | L436–480 | `## 工具调用示例` 节（5 个 bash 命令块） | 1429 | 工作流步骤 A1–A5 / B1–B3 中已内联相同命令及参数 |
| C3 | `agents/debian-rules-to-linyaps.agent.md` | L482–490 | `## 开始处理` 节（5 步骤） | 227 | 重复 Phase 1 工作流步骤 |
| C4 | `agents/debian-rules-to-linyaps.agent.md` | L492–497 | `## 注意事项` 节（5 条） | 576 | 重复 `## 约束条件` + `## Skills 加载` + `## Workspace 根目录` 节内容 |
| C5 | `for-multica/agent.md` | L368–388 | `## 约束` 节中 Desktop/Command、Version、Base/Runtime、多包合并、运行时依赖过滤、DESTDIR 黑名单 6 条 | ~1200 | 与 `agent.md` `## 约束条件` L103–145 逐字重复；保留 L389–394 Git 仓库约束（for-multica 特有） |
| C6 | `agents/debian-rules-to-linyaps.agent.md` | L113–115 | `### 多包合并约束` 子节 | 189 | 与 `src2linyaps.constraints` SKILL.md `### 3. 多包合并` 重复 |
| C7 | `agents/debian-rules-to-linyaps.agent.md` | L117–120 | `### 运行时依赖过滤约束` 子节 | 431 | 与 SKILL.md `### 4. 运行时依赖存在性核验` 重复 |
| C8 | `agents/debian-rules-to-linyaps.agent.md` | L132–137 | `### ${PREFIX} 安装目录约束` 子节 | 648 | 与 SKILL.md `### 1. ${PREFIX} 安装目录` 重复 |
| C9 | `agents/debian-rules-to-linyaps.agent.md` | L139–145 | `### DESTDIR 黑名单约束` 子节 | 623 | 与 SKILL.md `### 2. DESTDIR 黑名单` 重复 |
| | | | **C 组小计** | **~2793** | |

**C 组详细操作**：

**C1–C4（agent.md 尾部 4 节）**：`## 输出格式`、`## 工具调用示例`、`## 开始处理`、`## 注意事项` 是 `agent.md` 末尾 4 个连续节（L407–497），删除后 `agent.md` 以 `## 失败处理策略` 节的失败场景分类表结尾。

**C5（for-multica/agent.md `## 约束` 节去重）**：`## 约束` 节当前包含 7 条约束（L368–394）。L368–388 的 6 条（Desktop/Command、Version、Base/Runtime、多包合并、运行时依赖过滤、DESTDIR 黑名单）与 `agent.md` `## 约束条件` 逐字重复。仅保留 L389–394 的 `**Git 仓库（强制）**` 条目（for-multica 特有，agent.md 无此条）。删除后 `## 约束` 节仅含 Git 仓库约束一条。

**C6–C9（agent.md `## 约束条件` 去重）**：`## 约束条件` 节当前含 9 个子节。4 个（多包合并、运行时依赖过滤、${PREFIX} 安装目录、DESTDIR 黑名单）与 `src2linyaps.constraints` SKILL.md 重复——agent.md 在步骤 5（Phase 1）载入 constraints skill 后不应在约束条件节中逐字展开这些约束。保留 5 个 agent.md 特有子节：`### 任务身份契约`、`### Version 字段约束`、`### Base/Runtime 约束`、`### 构建参数提取约束`、`### 校验约束`、`### 构建缓存清理约束`（后两者含 agent.md 特有的载入优先级和清理脚本路径信息）。

#### D 组：刷新 docs 实现方案留档

用 v2 方案全文替换 `docs/agents-skills-perf-slim-plan.md` 当前 v1 内容（185 行）。替换后文件标题改为 `# agents-skills-perf-slim-v2 — Agent/Skills 上下文效率精简方案（净减版）`，首行说明改为指向 `local://agents-skills-perf-slim-v2-plan.md`。文件内容为 v2 方案完整副本（Context、Approach 含 A/B/C/D 组改动清单、Critical files、Verification、Assumptions），不含 v1 的 15 项改动清单和注入文本。

### 净减量计算

| 组 | 操作 | 字符变化 |
|----|------|---------|
| A | 删除 7 个建议性节 | −4505 |
| B | 保留 8 项内联编辑（已在工作树） | +1322（已计入当前增量） |
| C | 删除冗余节 | −2793 |
| **相对 HEAD 净变化** | | **+1322 − 4505 − 2793 = −5976** |
| **相对当前工作树净变化** | | **−4505 − 2793 = −7298** |

执行后 8 文件合计预计 **~69100 字符**（HEAD 71592 − 5976 + 4800 当前增量中 B 组已计 = ~69094），相对 HEAD **净减约 5500 字符**，相对当前工作树**净减约 7300 字符**。

> 注：B 组的 +1322 已在工作树中（是当前 +4800 增量的组成部分）。A 组删除撤销了 ~4505 字符的建议节，C 组删除 ~2793 字符冗余。最终相对 HEAD 的净变化 = 当前增量(+4800) − A 组删除(4505) − C 组删除(2793) = **−2498 字符**（即净减约 2500 字符相对 HEAD）。

**修正计算**（精确）：
- 当前工作树相对 HEAD：+4800 字符
- A 组删除（从工作树中移除）：−4505 字符
- C 组删除（从工作树中移除）：−2793 字符
- B 组不操作（已在工作树中）：0 字符变化
- **最终相对 HEAD：+4800 − 4505 − 2793 = −2498 字符**（净减约 2500 字符）

## Critical files

- `agents/debian-rules-to-linyaps.agent.md`（A1, C1–C4, C6–C9）
- `for-multica/agent.md`（A2, C5）
- `skills/src2linyaps.debian.analyze-control/SKILL.md`（A3）
- `skills/src2linyaps.debian.analyze-rules/SKILL.md`（A4）
- `skills/src2linyaps.debian.build-res-generate/SKILL.md`（A5）
- `skills/src2linyaps.debian.test-deps/SKILL.md`（A6）
- `skills/src2linyaps.debug/SKILL.md`（B5，不操作）
- `for-multica/skills/linyaps-upstream-query/SKILL.md`（A7）
- `docs/agents-skills-perf-slim-plan.md`（D 组，全文替换为 v2 方案）

**不改**（受保护 / 已合规）：
- `skills/src2linyaps.constraints/SKILL.md`（约束权威源，C6–C9 的引用对象）
- `skills/linyaps-src-init-dispatch/SKILL.md`
- `skills/linyaps-git-workflow/SKILL.md`
- 所有 `scripts/*.py|*.sh`
- `skills/config/`

## Verification

静态核对，不运行真实 apt/multica。

1. **建议性节已删除**（grep 确认 0 匹配）：
   ```bash
   grep -rn '上下文效率（强制）' agents/ for-multica/
   grep -rn '⚠️ 上下文效率' skills/ for-multica/
   # 预期：两组均 0 匹配
   ```

2. **内联编辑保留**（grep 确认仍存在）：
   ```bash
   grep -n '不预读 control 全文' agents/debian-rules-to-linyaps.agent.md
   grep -n 'override 段' agents/debian-rules-to-linyaps.agent.md
   grep -n '不预读 control 全文' for-multica/agent.md
   grep -n 'override 段' for-multica/agent.md
   grep -n '不批量预读' agents/debian-rules-to-linyaps.agent.md
   grep -c 'examples/ll-builder' skills/src2linyaps.debug/SKILL.md  # 预期 0
   # 预期：均非 0 匹配（debug 除外，预期 0）
   ```

3. **agent.md 尾部冗余节已删除**（grep 确认 0 匹配）：
   ```bash
   grep -n '## 输出格式' agents/debian-rules-to-linyaps.agent.md  # 预期 0
   grep -n '## 工具调用示例' agents/debian-rules-to-linyaps.agent.md  # 预期 0
   grep -n '## 开始处理' agents/debian-rules-to-linyaps.agent.md  # 预期 0
   grep -n '## 注意事项' agents/debian-rules-to-linyaps.agent.md  # 预期 0
   ```

4. **for-multica 约束去重**（确认仅保留 Git 仓库约束）：
   ```bash
   sed -n '/^## 约束$/,/^## /p' for-multica/agent.md | grep '^- \*\*'
   # 预期：仅 1 条 "Git 仓库（强制）"
   ```

5. **agent.md 约束条件去重**（确认 4 个重复子节已删）：
   ```bash
   grep -n '### 多包合并约束' agents/debian-rules-to-linyaps.agent.md  # 预期 0
   grep -n '### 运行时依赖过滤约束' agents/debian-rules-to-linyaps.agent.md  # 预期 0
   grep -n '### \${PREFIX} 安装目录约束' agents/debian-rules-to-linyaps.agent.md  # 预期 0
   grep -n '### DESTDIR 黑名单约束' agents/debian-rules-to-linyaps.agent.md  # 预期 0
   ```

6. **agent.md 保留子节仍存在**：
   ```bash
   grep -n '### 任务身份契约' agents/debian-rules-to-linyaps.agent.md
   grep -n '### Version 字段约束' agents/debian-rules-to-linyaps.agent.md
   grep -n '### Base/Runtime 约束' agents/debian-rules-to-linyaps.agent.md
   grep -n '### 构建参数提取约束' agents/debian-rules-to-linyaps.agent.md
   grep -n '### 校验约束' agents/debian-rules-to-linyaps.agent.md
   grep -n '### 构建缓存清理约束' agents/debian-rules-to-linyaps.agent.md
   # 预期：均 1 匹配
   ```

7. **净字符减少**（`git diff --stat` 确认负增量）：
   ```bash
   for f in \
     "agents/debian-rules-to-linyaps.agent.md" \
     "for-multica/agent.md" \
     "skills/src2linyaps.debian.analyze-control/SKILL.md" \
     "skills/src2linyaps.debian.analyze-rules/SKILL.md" \
     "skills/src2linyaps.debian.build-res-generate/SKILL.md" \
     "skills/src2linyaps.debian.test-deps/SKILL.md" \
     "skills/src2linyaps.debug/SKILL.md" \
     "for-multica/skills/linyaps-upstream-query/SKILL.md"; do
     wt=$(wc -c < "$f")
     head=$(git show "HEAD:$f" | wc -c)
     printf "%-60s delta=%+d\n" "$f" "$((wt - head))"
   done
   # 预期：合计为负值（≤ −2000）
   ```

8. **脚本语法不受影响**（确认未误改脚本）：
   ```bash
   bash -n skills/src2linyaps.debian.test-deps/scripts/test-build-deps.sh
   bash -n for-multica/skills/linyaps-upstream-query/scripts/query_upstream.sh
   python3 -m py_compile skills/src2linyaps.debian.analyze-control/scripts/init-control.py
   python3 -m py_compile skills/src2linyaps.debian.analyze-rules/scripts/analyze-rules.py
9. **docs 留档已刷新为 v2 方案**：
   ```bash
   head -1 docs/agents-skills-perf-slim-plan.md
   # 预期：# agents-skills-perf-slim-v2 — Agent/Skills 上下文效率精简方案（净减版）
   grep -c 'agents-skills-perf-slim-v2-plan.md' docs/agents-skills-perf-slim-plan.md  # 预期 ≥1
   grep -c '## D 组' docs/agents-skills-perf-slim-plan.md  # 预期 1（D 组改动清单存在）
   grep -c '15 项改动' docs/agents-skills-perf-slim-plan.md  # 预期 0（v1 内容已清除）
   ```

## Assumptions

- B 组 8 项内联编辑已在工作树中（前序方案应用），本方案不重新编辑这些位置——只删除 A/C 组内容。
- `agent.md` 尾部 4 节（`## 输出格式` / `## 工具调用示例` / `## 开始处理` / `## 注意事项`）在 HEAD 中已存在（非前序方案引入），删除是顺带的冗余精简，不影响行为——工作流步骤已内联全部命令和参数。
- `for-multica/agent.md` `## 约束` 节的 6 条通用约束与 `agent.md` `## 约束条件` 逐字重复。for-multica 载入 `src2linyaps.constraints` skill 后（步骤 1.5），这些约束由 SKILL.md 权威定义，不需要在 agent 文件中逐字复述。仅保留 Git 仓库约束（for-multica 特有，agent.md 无此条）。
- `agent.md` `## 约束条件` 中 4 个子节（多包合并 / 运行时依赖过滤 / ${PREFIX} / DESTDIR 黑名单）与 `src2linyaps.constraints` SKILL.md 重复。agent.md 在步骤 5 载入 constraints skill，约束条件节不应逐字展开 SKILL.md 已定义的约束。保留的 5 个子节含 agent.md 特有信息：任务身份契约（UUID 格式）、Version/Base/Runtime 载入优先级、构建参数提取（路径 B 回退）、校验约束（脚本路径）、构建缓存清理（clean_project_cache.sh 路径）。
- `skills/src2linyaps.constraints/SKILL.md` 是约束的唯一权威源（C6–C9 的引用对象），不修改。
- 删除建议性节后，内联收敛编辑（B 组）仍提供行为约束——agent 文件不需要独立的"节省上下文"节，实际的内联读取指令才是行为杠杆。
- A 组建议性节是前序方案唯一新增的内容（B 组内联编辑是修改既有行），删除 A 组精确撤销前序方案的不利改动，不影响 B 组。
