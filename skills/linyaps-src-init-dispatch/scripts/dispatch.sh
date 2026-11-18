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

CONFIG_FILE=""
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
    --workspace=*) WORKSPACE="${1#*=}" ;;
    --output=*) OUTPUT_FILE="${1#*=}" ;;
    --pkgName=*) PKG_NAME="${1#*=}" ;;
    --project_dir=*) PROJECT_DIR="${1#*=}" ;;
    --arch=*) ARCH="${1#*=}" ;;
    --workflow_type=*) WORKFLOW_TYPE="${1#*=}" ;;
    --data-dir=*) DATA_DIR="${1#*=}" ;;
    --config=*) CONFIG_FILE="${1#*=}" ;;
    --success=*) SUCCESS_COUNT="${1#*=}" ;;
    --fail=*) FAIL_COUNT="${1#*=}" ;;
    --agent_name=*) AGENT_NAME="${1#*=}" ;;
    --issue-id=*) ISSUE_ID_ARG="${1#*=}" ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
  shift
done

output_json() { if [[ -n "$OUTPUT_FILE" ]]; then printf '%s\n' "$1" > "$OUTPUT_FILE"; else printf '%s\n' "$1"; fi; }
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
is_uuid() { [[ "$1" =~ $UUID_RE ]]; }
json_reason() { python3 -c 'import json,sys; print(json.dumps({"assigned":False,"blocked":True,"blocked_reason":sys.argv[1]}))' "$1"; }
get_issue_id() {
  local env_id="${MULTICA_ISSUE_TASK_ID:-}"
  local id="${env_id:-$ISSUE_ID_ARG}"
  [[ -n "$ISSUE_ID_ARG" && -n "$env_id" && "$ISSUE_ID_ARG" != "$env_id" ]] && return 3
  [[ -n "$id" ]] && is_uuid "$id" || return 4
  printf '%s\n' "$id"
}

if [[ "$ACTION" == "assign_packer" ]]; then
  if [[ -z "$CONFIG_FILE" || ! -f "$CONFIG_FILE" ]]; then output_json "$(json_reason config_required)"; exit 0; fi
  if [[ -z "$PKG_NAME" || -z "$PROJECT_DIR" || -z "$ARCH" || -z "$WORKSPACE" ]]; then output_json "$(json_reason required_parameter)"; exit 0; fi
  ISSUE_ID=""; if ! ISSUE_ID=$(get_issue_id); then output_json "$(json_reason issue_id_invalid)"; exit 0; fi
  command -v multica >/dev/null 2>&1 || { output_json "$(json_reason cli_unavailable)"; exit 0; }
  AGENTS_JSON=$(python3 - "$CONFIG_FILE" <<'PY'
import json,sys
try:
 c=json.load(open(sys.argv[1])); print(json.dumps([a for a in c.get('assignment',{}).get('agents',[]) if 'linyaps_packaging' in a.get('capabilities',[])]))
except Exception: print('[]')
PY
)
  PLATFORM_JSON=$(multica agent list --output json 2>/dev/null) || { output_json "$(json_reason agent_list_failed)"; exit 0; }
  CANDIDATES=$(printf '%s\n%s\n' "$AGENTS_JSON" "$PLATFORM_JSON" | python3 -c '
import json,sys
lines=sys.stdin.read().split("\n",1)
cfg=json.loads(lines[0]); raw=json.loads(lines[1]); agents=raw.get("agents",raw) if isinstance(raw,dict) else raw
byname={a.get("name"):a for a in agents}
for c in cfg:
 a=byname.get(c.get("name"))
 if a and isinstance(a.get("id"),str): print(json.dumps({"name":c.get("name",""),"id":a["id"],"status":a.get("status","unknown")}))
')
  SELECTED_NAME=""; SELECTED_UUID=""; SELECTED_STATUS="unknown"; FALLBACK=""
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    name=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["name"])' <<<"$row")
    uuid=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])' <<<"$row")
    status=$(python3 -c 'import json,sys;print(json.load(sys.stdin).get("status","unknown"))' <<<"$row")
    is_uuid "$uuid" || continue
    [[ -z "$FALLBACK" ]] && FALLBACK="$name|$uuid|$status"
    [[ "$status" == "idle" ]] && { SELECTED_NAME="$name"; SELECTED_UUID="$uuid"; SELECTED_STATUS="idle"; break; }
  done <<<"$CANDIDATES"
  if [[ -z "$SELECTED_NAME" && -n "$FALLBACK" ]]; then IFS='|' read -r SELECTED_NAME SELECTED_UUID SELECTED_STATUS <<<"$FALLBACK"; fi
  [[ -n "$SELECTED_NAME" ]] || { output_json "$(json_reason agent_unavailable)"; exit 0; }
  [[ "$SELECTED_STATUS" == "idle" || "$SELECTED_STATUS" == "busy" || "$SELECTED_STATUS" == "running" ]] || SELECTED_STATUS="unknown"
  WT="${WORKFLOW_TYPE:-debian-rules-to-linyaps}"; MENTION="[@${SELECTED_NAME}](mention://agent/${SELECTED_UUID})"
  multica workspace switch "$WORKSPACE" >/dev/null 2>&1 || true
  if ! multica issue comment add "$ISSUE_ID" --content "${MENTION} 请按照 ${WT} 流程执行 ${PROJECT_DIR} 打包任务（${ARCH}）" >/dev/null 2>&1; then output_json "$(json_reason comment_failed)"; exit 0; fi
  ASSIGNED=false; REASON=""
  multica issue assign "$ISSUE_ID" --to-id "$SELECTED_UUID" >/dev/null 2>&1 && ASSIGNED=true || REASON="assign_failed"
  if [[ "$ASSIGNED" == true && -n "$DATA_DIR" ]]; then mkdir -p "$(dirname "$DATA_DIR")"; printf 'assigned_packer, %s, %s, %s, %s\n' "$PKG_NAME" "$SELECTED_NAME" "$ARCH" "$(date +'%Y-%m-%d %H:%M:%S')" >> "$DATA_DIR/assignment.log"; fi
  output_json "$(python3 - "$ASSIGNED" "$SELECTED_NAME" "$SELECTED_UUID" "$SELECTED_STATUS" "$REASON" <<'PY'
import json,sys
print(json.dumps({'assigned':sys.argv[1]=='true','target_agent':sys.argv[2],'target_agent_uuid':sys.argv[3],'agent_status':sys.argv[4],'blocked_reason':sys.argv[5]}))
PY
)"; exit 0

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
