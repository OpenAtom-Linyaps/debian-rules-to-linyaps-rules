#!/usr/bin/env bash
# linyaps-src-init-dispatch: dispatch.sh
#
# 统一指派入口脚本，三种 action：
#   assign_packer         — Git 提交成功后向 linyaps-packer 发起指派
#   update_issue_status   — 汇总后更新 issue 状态
#   check_agent_status    — 查询单个 agent 实时状态
#
# 使用方式：
#   bash dispatch.sh assign_packer --pkgName=<name> --project_dir=<dir> --arch=<arch> --workflow_type=<type> [--data-dir=<path>] [--workspace=<slug>] [--config=<path>]
#   bash dispatch.sh update_issue_status --success=<n> --fail=<n> [--workspace=<slug>]
#   bash dispatch.sh check_agent_status --agent_name=<name> [--workspace=<slug>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SKILL_ROOT/../.." && pwd)"

ACTION="${1:-}"
shift || true

# 参数
WORKSPACE=""
OUTPUT_FILE=""
PKG_NAME=""
PROJECT_DIR=""
ARCH=""
WORKFLOW_TYPE=""
DATA_DIR=""
CONFIG_FILE="${REPO_ROOT}/for-multica/agent-config.json"
SUCCESS_COUNT=0
FAIL_COUNT=0
AGENT_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace=*)    WORKSPACE="${1#*=}" ;;
    --output=*)       OUTPUT_FILE="${1#*=}" ;;
    --pkgName=*)      PKG_NAME="${1#*=}" ;;
    --project_dir=*)  PROJECT_DIR="${1#*=}" ;;
    --arch=*)         ARCH="${1#*=}" ;;
    --workflow_type=*) WORKFLOW_TYPE="${1#*=}" ;;
    --data-dir=*)     DATA_DIR="${1#*=}" ;;
    --config=*)       CONFIG_FILE="${1#*=}" ;;
    --success=*)      SUCCESS_COUNT="${1#*=}" ;;
    --fail=*)         FAIL_COUNT="${1#*=}" ;;
    --agent_name=*)   AGENT_NAME="${1#*=}" ;;
    *)
      echo "未知参数: $1" >&2
      exit 1
      ;;
  esac
  shift
done

output_json() {
  local json="$1"
  if [[ -n "$OUTPUT_FILE" ]]; then
    echo "$json" > "$OUTPUT_FILE"
  else
    echo "$json"
  fi
}

# UUID 精确校验（小写十六进制）
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

is_uuid() {
  [[ "$1" =~ $UUID_RE ]]
}

# 返回当前 issue 的 UUID id；返回码: 0=成功 1=无 issue 2=CLI 异常
get_issue_id() {
  local out
  out=$(multica issue list --output json --limit 1 2>/dev/null) || return 2
  [[ -z "$out" ]] && return 1
  python3 -c "import json,sys
d=json.load(sys.stdin)
print(d['issues'][0]['id'] if d.get('issues') else '')" <<<"$out"
}

# ---- assign_packer ----
if [[ "$ACTION" == "assign_packer" ]]; then
  if [[ -z "$PKG_NAME" || -z "$PROJECT_DIR" || -z "$ARCH" ]]; then
    echo '{"error":"缺少必填参数: --pkgName, --project_dir, --arch"}' >&2
    exit 1
  fi
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo '{"error":"agent-config.json 不存在: '"$CONFIG_FILE"'"}' >&2
    exit 1
  fi

  # 读取配置，筛选 linyaps_packaging agent
  AGENTS_JSON=$(python3 -c "
import json
with open('$CONFIG_FILE') as f:
    cfg = json.load(f)
agents = cfg.get('assignment', {}).get('agents', [])
result = [a for a in agents if 'linyaps_packaging' in a.get('capabilities', [])]
print(json.dumps(result))
" 2>/dev/null) || AGENTS_JSON="[]"

  AGENT_COUNT=$(echo "$AGENTS_JSON" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null) || AGENT_COUNT=0

  if [[ "$AGENT_COUNT" -eq 0 ]]; then
    echo "[WARN] 未找到 capabilities 包含 linyaps_packaging 的 agent" >&2
    output_json "{\"assigned\":false,\"target_agent\":\"\",\"timestamp\":\"$(date +'%Y-%m-%d %H:%M:%S')\",\"agent_status\":\"unknown\"}"
    exit 0
  fi

  # 状态检查 + 选择最佳节点
  SELECTED_AGENT=""
  SELECTED_UUID=""
  SELECTED_STATUS="unknown"
  for row in $(echo "$AGENTS_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for a in data:
    print(f'{a[\"id\"]}|{a.get(\"name\", a[\"id\"])}')
" 2>/dev/null); do
    AGENT_ID="${row%%|*}"
    AGENT_NAME="${row##*|}"
    STATUS_RESULT=$(bash "$SCRIPT_DIR/check-agent-status.sh" \
      ${WORKSPACE:+-w "$WORKSPACE"} -n "$AGENT_NAME" -o json 2>/dev/null || true)
    AGENT_UUID=""
    if [[ -n "$STATUS_RESULT" ]]; then
      parse=$(echo "$STATUS_RESULT" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    agent = data.get('agent', {})
    print(agent.get('status', 'unknown'))
    print(agent.get('id', ''))
except Exception:
    print('unknown')
    print('')
" 2>/dev/null) || parse=$'unknown\n'
      STATUS="$(printf '%s\n' "$parse" | sed -n '1p')"
      AGENT_UUID="$(printf '%s\n' "$parse" | sed -n '2p')"
    else
      STATUS="unknown"
    fi
    if [[ ! -z "$AGENT_UUID" ]] && ! is_uuid "$AGENT_UUID"; then
      echo "[WARN] agent ${AGENT_NAME} 未返回有效 UUID，指派将回退到名称" >&2
      AGENT_UUID=""
    fi
    if [[ "$STATUS" == "idle" ]]; then
      SELECTED_AGENT="$AGENT_NAME"
      SELECTED_UUID="$AGENT_UUID"
      SELECTED_STATUS="idle"
      echo "[INFO] 目标智能体 ${AGENT_NAME} 空闲，可立即指派" >&2
      break
    elif [[ -z "$SELECTED_AGENT" ]]; then
      SELECTED_AGENT="$AGENT_NAME"
      SELECTED_UUID="$AGENT_UUID"
      SELECTED_STATUS="$STATUS"
    fi
  done

  if [[ "$SELECTED_STATUS" == "busy" || "$SELECTED_STATUS" == "running" ]]; then
    echo "[WARN] 所有打包智能体繁忙，随机指派 ${SELECTED_AGENT}（由平台排队处理）" >&2
  elif [[ "$SELECTED_STATUS" == "unknown" ]]; then
    echo "[WARN] 无法查询目标智能体状态，直接发起指派" >&2
  fi

  # 指派执行
  ASSIGNED=false
  BLOCKED_REASON=""
  if command -v multica &>/dev/null; then
    if [[ -n "$WORKSPACE" ]]; then
      multica workspace switch "$WORKSPACE" >/dev/null 2>&1 || true
    fi
    ISSUE_ID=$(get_issue_id) || BLOCKED_REASON=$?
    if [[ "$BLOCKED_REASON" != "2" && -n "$ISSUE_ID" ]]; then
      if ! is_uuid "$ISSUE_ID"; then
        BLOCKED_REASON="invalid_uuid"
        echo "[WARN] ISSUE_ID 非 UUID（${ISSUE_ID}），跳过指派" >&2
      fi
    elif [[ "$BLOCKED_REASON" == "2" ]]; then
      echo "[WARN] multica CLI 查询失败" >&2
    else
      BLOCKED_REASON="issue_id_not_found"
      echo "[WARN] 无法查询 ISSUE_ID，跳过指派" >&2
    fi

    if [[ -z "$BLOCKED_REASON" ]]; then
      WT="${WORKFLOW_TYPE:-debian-rules-to-linyaps}"
      # Step 1: 发送 @ 提及评论（通知 agent），mention 用 UUID 绑定
      if [[ -n "$SELECTED_UUID" ]]; then
        MENTION="[@${SELECTED_AGENT}](mention://agent/${SELECTED_UUID})"
      else
        MENTION="@${SELECTED_AGENT}"
      fi
      multica issue comment add "$ISSUE_ID" \
        --content "${MENTION} 请按照 ${WT} 流程执行 ${PROJECT_DIR} 打包任务（${ARCH}）" \
        2>/dev/null || echo "[WARN] multica comment 发送失败" >&2

      # Step 2: 指派 issue 给目标 agent（assign 负责人，精确 UUID）
      if [[ -n "$SELECTED_UUID" ]]; then
        if multica issue assign "$ISSUE_ID" --to-id "$SELECTED_UUID" \
          2>/dev/null; then
          ASSIGNED=true
        else
          echo "[WARN] multica assign --to-id 失败" >&2
        fi
      elif multica issue assign "$ISSUE_ID" --to "$SELECTED_AGENT" \
        2>/dev/null; then
        ASSIGNED=true
      else
        echo "[WARN] multica assign 失败" >&2
      fi
    fi
  else
    BLOCKED_REASON="cli_unavailable"
    echo "[WARN] multica CLI 不可用，跳过指派" >&2
  fi

  # 记录指派日志
  if [[ -n "$DATA_DIR" ]]; then
    mkdir -p "$(dirname "$DATA_DIR" 2>/dev/null || echo "$DATA_DIR")" 2>/dev/null || true
    echo "assigned_packer, ${PKG_NAME}, ${SELECTED_AGENT}, ${ARCH}, $(date +'%Y-%m-%d %H:%M:%S')" >> "${DATA_DIR}/assignment.log" 2>/dev/null || true
  fi

  output_json "$(cat <<JSON
{"assigned":${ASSIGNED},"target_agent":"${SELECTED_AGENT}","target_agent_uuid":"${SELECTED_UUID:-""}","blocked_reason":"${BLOCKED_REASON:-}" ,"timestamp":"$(date +'%Y-%m-%d %H:%M:%S')","agent_status":"${SELECTED_STATUS}"}
JSON
)"

# ---- update_issue_status ----
elif [[ "$ACTION" == "update_issue_status" ]]; then
  if [[ "$FAIL_COUNT" -eq 0 ]]; then
    ISSUE_STATUS="审查完成"
  elif [[ "$SUCCESS_COUNT" -eq 0 ]]; then
    ISSUE_STATUS="阻塞"
  else
    ISSUE_STATUS="部分完成"
  fi

  COMMENT_ID=""
  BLOCKED_REASON=""
  if command -v multica &>/dev/null; then
    if [[ -n "$WORKSPACE" ]]; then
      multica workspace switch "$WORKSPACE" >/dev/null 2>&1 || true
    fi
    ISSUE_ID=$(get_issue_id) || BLOCKED_REASON=$?
    if [[ "$BLOCKED_REASON" != "2" && -n "$ISSUE_ID" ]] && is_uuid "$ISSUE_ID"; then
      COMMENT_ID=$(multica issue comment add "$ISSUE_ID" \
        --content "結果：成功 ${SUCCESS_COUNT} / 失敗 ${FAIL_COUNT}" \
        2>/dev/null | grep -oP 'comment-\d+' | head -1) || COMMENT_ID=""
    fi
  fi

  output_json "$(cat <<JSON
{"issue_status":"${ISSUE_STATUS}","comment_id":"${COMMENT_ID:-""}"}
JSON
)"

# ---- check_agent_status ----
elif [[ "$ACTION" == "check_agent_status" ]]; then
  if [[ -z "$AGENT_NAME" ]]; then
    echo '{"error":"缺少必填参数: --agent_name"}' >&2
    exit 1
  fi
  bash "$SCRIPT_DIR/check-agent-status.sh" \
    ${WORKSPACE:+-w "$WORKSPACE"} \
    -n "$AGENT_NAME" \
    -o json

else
  echo "未知 action: ${ACTION}" >&2
  echo "可用 action: assign_packer, update_issue_status, check_agent_status" >&2
  exit 1
fi
