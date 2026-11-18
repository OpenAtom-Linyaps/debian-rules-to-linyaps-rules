#!/usr/bin/env bash
set -euo pipefail

VERSION="1.0.0"
DEFAULT_WORKSPACE="linyaps"

usage() {
  cat <<EOF
check-agent-status.sh v$VERSION

用法: $(basename "$0") [选项]

检查指定 workspace 中某 agent 的运行状态，列出正在运行的任务（排除已结束任务）。

选项:
  -w, --workspace <slug>   工作空间 slug（默认: $DEFAULT_WORKSPACE）
  -n, --name     <name>    agent 名称（必填）
  -o, --output   <format>  输出格式: table / json（默认 table）
  -h, --help               显示此帮助信息

示例:
  $(basename "$0") -n linyaps-packer-1
  $(basename "$0") -w linyaps -n linyaps-packer-1 -o json
EOF
  exit 0
}

WORKSPACE="$DEFAULT_WORKSPACE"
AGENT_NAME=""
OUTPUT="table"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -w|--workspace)
      WORKSPACE="$2"; shift 2 ;;
    -n|--name)
      AGENT_NAME="$2"; shift 2 ;;
    -o|--output)
      OUTPUT="$2"; shift 2 ;;
    -h|--help)
      usage ;;
    *)
      echo "未知选项: $1" >&2
      usage ;;
  esac
done

if [[ -z "$AGENT_NAME" ]]; then
  echo "错误: --name 是必填参数" >&2
  usage
fi

if [[ "$OUTPUT" != "table" && "$OUTPUT" != "json" ]]; then
  echo "错误: --output 必须是 table 或 json" >&2
  usage
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# ---------- [1/3] switch workspace ----------
echo "[1/3] 切换 workspace ..." >&2
multica workspace switch "$WORKSPACE" >/dev/null 2>&1 || true
multica workspace list --output json > "$TMPDIR/workspaces.json" 2>&1
WORKSPACE_ID=$(python3 -c "
import json, sys
try:
    data = json.load(open('$TMPDIR/workspaces.json'))
    if isinstance(data, dict):
        data = data.get('workspaces', data) or data
    for w in data:
        if w.get('slug') == '$WORKSPACE':
            print(w.get('id', ''))
            break
except Exception:
    print('')
")
echo "       workspace: $WORKSPACE → $WORKSPACE_ID" >&2

# ---------- [2/3] find agent ----------
echo "[2/3] 查找 agent ..." >&2
multica agent list --output json > "$TMPDIR/agents.json" 2>&1

python3 -c "
import json, sys
data = json.load(open('$TMPDIR/agents.json'))
name = '$AGENT_NAME'
for a in data:
    if a['name'] == name:
        out = {'id': a['id'], 'name': a['name'], 'status': a['status'], 'updated_at': a.get('updated_at', '')}
        json.dump(out, open('$TMPDIR/agent.json', 'w'))
        sys.exit(0)
print('', file=open('$TMPDIR/agent_not_found', 'w'))
"

if [[ -f "$TMPDIR/agent_not_found" ]]; then
  echo "错误: 未找到匹配的 agent: $AGENT_NAME" >&2
  echo "可用 agent:" >&2
  python3 -c "import json; [print(f'  {a[\"name\"]} ({a[\"id\"]})') for a in json.load(open('$TMPDIR/agents.json'))]" >&2
  exit 1
fi

AGENT_ID=$(python3 -c "import json; print(json.load(open('$TMPDIR/agent.json'))['id'])")
AGENT_STATUS=$(python3 -c "import json; print(json.load(open('$TMPDIR/agent.json'))['status'])")
AGENT_UPDATED=$(python3 -c "import json; print(json.load(open('$TMPDIR/agent.json')).get('updated_at', ''))")
echo "       agent: $AGENT_NAME → $AGENT_ID (status: $AGENT_STATUS)" >&2

# ---------- [3/3] query tasks ----------
echo "[3/3] 查询任务状态 ..." >&2
multica agent tasks "$AGENT_ID" --output json > "$TMPDIR/tasks.json" 2>&1

python3 -c "
import json
data = json.load(open('$TMPDIR/tasks.json'))
running = [t for t in data if t['status'] == 'running']
json.dump(running, open('$TMPDIR/running_tasks.json', 'w'), indent=2, ensure_ascii=False)
"

RUNNING_COUNT=$(python3 -c "import json; print(len(json.load(open('$TMPDIR/running_tasks.json'))))")

# ---------- output ----------
if [[ "$OUTPUT" == "json" ]]; then
  python3 -c "
import json
agent = json.load(open('$TMPDIR/agent.json'))
running = json.load(open('$TMPDIR/running_tasks.json'))
result = {
    'workspace': {'slug': '$WORKSPACE', 'id': '$WORKSPACE_ID'},
    'agent': agent,
    'running_tasks': running
}
print(json.dumps(result, indent=2, ensure_ascii=False))
"
else
  echo ""
  echo "Agent: $AGENT_NAME ($AGENT_ID)"
  echo "状态: $AGENT_STATUS"
  if [[ -n "$AGENT_UPDATED" ]]; then
    echo "最后活跃: $AGENT_UPDATED"
  fi
  if [[ "$AGENT_STATUS" == "idle" ]]; then
    echo "无运行中任务"
  else
    if [[ "$RUNNING_COUNT" -gt 0 ]]; then
      echo "运行中任务 ($RUNNING_COUNT):"
      echo ""
      python3 -c "
import json
tasks = json.load(open('$TMPDIR/running_tasks.json'))
print(f'{\"TASK ID\":<40} {\"STATUS\":<12} {\"CREATED_AT\":<25}')
print('-' * 80)
for t in tasks:
    tid = t['id']
    st = t['status']
    ca = t.get('created_at', '')
    print(f'{tid:<40} {st:<12} {ca:<25}')
      "
      echo "---"
      echo "Total: $RUNNING_COUNT running tasks"
    else
      echo "无运行中任务（状态非 idle，但无 running 任务）"
    fi
  fi
fi