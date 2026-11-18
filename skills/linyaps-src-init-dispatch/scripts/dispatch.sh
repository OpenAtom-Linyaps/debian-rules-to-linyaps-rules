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
ISSUE_ID_ARG=""
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
    --issue-id=*)     ISSUE_ID_ARG="${1#*=}" ;;
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

# The handoff UUID is the only authoritative task identity.
get_issue_id() {
  local env_id="${MULTICA_ISSUE_TASK_ID:-}"
  if [[ -n "$ISSUE_ID_ARG" && -n "$env_id" && "$ISSUE_ID_ARG" != "$env_id" ]]; then return 3; fi
  local id="${env_id:-$ISSUE_ID_ARG}"
  if [[ -z "$id" ]]; then return 4; fi
  if ! is_uuid "$id"; then return 5; fi
  printf '%s\n' "$id"
}

blocked_json() {
  local reason="$1"; output_json "{\"assigned\":false,\"blocked\":true,\"blocked_reason\":\"$reason\"}"
}


# ---- assign_packer ----
  if [[ -z "${MULTICA_ISSUE_TASK_ID:-}" && -z "$ISSUE_ID_ARG" ]]; then blocked_json "issue_id_required"; exit 0; fi
  if [[ -n "${MULTICA_ISSUE_TASK_ID:-}" ]] && ! is_uuid "$MULTICA_ISSUE_TASK_ID"; then blocked_json "invalid_uuid"; exit 0; fi
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
      parse=$(echo "$STATUS_RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); a=d.get('agent',{}); print(a.get('status','unknown')); print(a.get('id',''))" 2>/dev/null) || parse=$'unknown\n'
      STATUS="$(printf '%s\n' "$parse" | sed -n '1p')"
      AGENT_UUID="$(printf '%s\n' "$parse" | sed -n '2p')"
    else STATUS="unknown"; fi
    if [[ "$STATUS" == "idle" && "$AGENT_UUID" == "$AGENT_ID" ]] && is_uuid "$AGENT_UUID"; then
      SELECTED_AGENT="$AGENT_NAME"; SELECTED_UUID="$AGENT_UUID"; SELECTED_STATUS="idle"; break
    fi
  done
  if [[ -z "$SELECTED_AGENT" ]]; then blocked_json "agent_unavailable"; exit 0; fi
  ASSIGNED=false; BLOCKED_REASON=""
  if ! command -v multica &>/dev/null; then blocked_json "cli_unavailable"; exit 0; fi
  [[ -n "$WORKSPACE" ]] && multica workspace switch "$WORKSPACE" >/dev/null 2>&1 || true
  if ! ISSUE_ID=$(get_issue_id); then blocked_json "issue_id_required"; exit 0; fi
  WT="${WORKFLOW_TYPE:-debian-rules-to-linyaps}"
  MENTION="[@${SELECTED_AGENT}](mention://agent/${SELECTED_UUID})"
  if ! multica issue comment add "$ISSUE_ID" --content "${MENTION} 请按照 ${WT} 流程执行 ${PROJECT_DIR} 打包任务（${ARCH}）" 2>/dev/null; then
    blocked_json "comment_failed"; exit 0
  fi
  if multica issue assign "$ISSUE_ID" --to-id "$SELECTED_UUID" 2>/dev/null; then ASSIGNED=true; else BLOCKED_REASON="assign_failed"; fi

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
  if ! ISSUE_ID=$(get_issue_id); then
    BLOCKED_REASON="issue_id_required"
  elif ! command -v multica &>/dev/null; then
    BLOCKED_REASON="cli_unavailable"
  elif COMMENT_ID=$(multica issue comment add "$ISSUE_ID" --content "結果：成功 ${SUCCESS_COUNT} / 失敗 ${FAIL_COUNT}" 2>/dev/null); then
    :
  else
    BLOCKED_REASON="comment_failed"
  fi
  output_json "{\"issue_status\":\"${ISSUE_STATUS}\",\"comment_id\":\"${COMMENT_ID}\",\"blocked\":$([[ -n "$BLOCKED_REASON" ]] && echo true || echo false),\"blocked_reason\":\"${BLOCKED_REASON}\"}"
  exit 0

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
