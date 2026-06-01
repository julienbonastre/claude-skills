#!/usr/bin/env bash
# ServiceNow Change Management REST helper (multi-environment).
#
# Uses the Table API (`/api/now/table/change_request`). Some instances do not
# have the `sn_chg_rest` Scripted REST API installed — the Table API works
# regardless, so this helper sticks to it.
#
# Auth: HTTP Basic. Password is pulled from macOS Keychain at call time and
# passed to curl via `-K -` (config on stdin) so it never appears in argv/`ps`.
#
# Environments: dev (default) | test | prod. Select with `--env <e>` or SNOW_ENV.
# Config (non-secret) lives in ~/.claude/skills/snow-change/.snow-env — copy
# .snow-env.example and fill in your own values:
#   SNOW_URI_DEV/TEST/PROD   — instance base URL per env
#   SNOW_USER_DEV/TEST/PROD  — API account per env
#   SNOW_KC_PREFIX           — Keychain service-name prefix (default servicenow)
# Passwords are stored per env in the Keychain:
#   security add-generic-password -U -s "<prefix>-<env>" -a "<user>" -w
#
# PROD WRITE GUARD: create/update/transition against prod refuse unless
# SNOW_PROD_WRITE_OK=1 is set. Reads are always allowed.
set -euo pipefail

CONFIG="${SNOW_CONFIG:-$HOME/.claude/skills/snow-change/.snow-env}"
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && source "$CONFIG"

ENV="${SNOW_ENV:-dev}"
pos=()
while [ $# -gt 0 ]; do
  case "$1" in
    --env)   ENV="${2:?--env needs a value}"; shift 2 ;;
    --env=*) ENV="${1#*=}"; shift ;;
    *)       pos+=("$1"); shift ;;
  esac
done
set -- "${pos[@]:-}"

case "$ENV" in dev|test|prod) ;; *) echo "ERROR: --env must be dev|test|prod (got '$ENV')" >&2; exit 2 ;; esac
EU="$(printf '%s' "$ENV" | tr '[:lower:]' '[:upper:]')"

base_var="SNOW_URI_${EU}"; user_var="SNOW_USER_${EU}"
SNOW_BASE_URL="${!base_var:-}"; SNOW_USER="${!user_var:-}"
: "${SNOW_BASE_URL:?set $base_var in $CONFIG}"
: "${SNOW_USER:?set $user_var in $CONFIG}"
KC_SERVICE="${SNOW_KC_PREFIX:-servicenow}-${ENV}"

SNOW_PASS="$(security find-generic-password -s "$KC_SERVICE" -a "$SNOW_USER" -w 2>/dev/null)" || {
  echo "ERROR: no Keychain entry '$KC_SERVICE' for account '$SNOW_USER'." >&2
  echo "Store it: security add-generic-password -U -s '$KC_SERVICE' -a '$SNOW_USER' -w" >&2
  exit 1
}

require_prod_ok() {
  if [ "$ENV" = "prod" ] && [ "${SNOW_PROD_WRITE_OK:-}" != "1" ]; then
    echo "REFUSED: write to PROD blocked. Re-run with SNOW_PROD_WRITE_OK=1 after explicit confirmation." >&2
    exit 3
  fi
}

api() { # method path [json-body]
  local method="$1" path="$2" body="${3:-}"
  local curl_args=(-sS --fail-with-body -K - -H "Accept: application/json" -X "$method")
  [ -n "$body" ] && curl_args+=(-H "Content-Type: application/json" --data "$body")
  printf 'user = "%s:%s"\n' "$SNOW_USER" "$SNOW_PASS" \
    | curl "${curl_args[@]}" "${SNOW_BASE_URL}${path}"
}

# Resolve <id> to sys_id. Accepts CHG-number or raw sys_id (32 hex chars).
resolve_sys_id() {
  local id="${1:?id required}"
  if [[ "$id" =~ ^[0-9a-f]{32}$ ]]; then printf '%s' "$id"; return; fi
  if [[ "$id" =~ ^CHG[0-9]+$ ]]; then
    api GET "/api/now/table/change_request?sysparm_query=number=${id}&sysparm_limit=1&sysparm_fields=sys_id" \
      | python3 -c "import sys,json; r=json.loads(sys.stdin.read()).get('result',[]); print(r[0]['sys_id'] if r else '')"
    return
  fi
  echo "ERROR: '$id' is neither a sys_id nor a CHG number" >&2; exit 2
}

cmd="${1:-}"; shift || true
case "$cmd" in
  whoami)
    api GET "/api/now/table/sys_user?sysparm_query=user_name=${SNOW_USER}&sysparm_limit=1&sysparm_fields=user_name,name,sys_id,email"
    ;;
  get)
    id="${1:?sys_id or CHG number required}"; shift || true
    sys_id="$(resolve_sys_id "$id")"
    [ -z "$sys_id" ] && { echo "ERROR: change not found: $id" >&2; exit 4; }
    api GET "/api/now/table/change_request/${sys_id}?sysparm_display_value=${1:-all}"
    ;;
  list)
    n="${1:-5}"
    api GET "/api/now/table/change_request?sysparm_query=type=normal^ORDERBYDESCsys_created_on&sysparm_limit=${n}&sysparm_display_value=all&sysparm_fields=number,short_description,state,assignment_group,sys_created_on,start_date,end_date"
    ;;
  mine)
    n="${1:-10}"
    api GET "/api/now/table/change_request?sysparm_query=type=normal^opened_by.user_name=${SNOW_USER}^ORDERBYDESCsys_created_on&sysparm_limit=${n}&sysparm_display_value=all&sysparm_fields=number,short_description,state,start_date,end_date,sys_id"
    ;;
  create)
    require_prod_ok
    body="${1:?json body required}"
    api POST "/api/now/table/change_request" "$body"
    ;;
  update)
    require_prod_ok
    id="${1:?sys_id or CHG number required}"; body="${2:?json body required}"
    sys_id="$(resolve_sys_id "$id")"
    [ -z "$sys_id" ] && { echo "ERROR: change not found: $id" >&2; exit 4; }
    api PATCH "/api/now/table/change_request/${sys_id}" "$body"
    ;;
  transition)
    require_prod_ok
    id="${1:?sys_id or CHG number required}"; state="${2:?state required}"
    sys_id="$(resolve_sys_id "$id")"
    [ -z "$sys_id" ] && { echo "ERROR: change not found: $id" >&2; exit 4; }
    api PATCH "/api/now/table/change_request/${sys_id}" "{\"state\":\"${state}\"}"
    ;;
  group)
    q="${1:?name fragment required}"
    api GET "/api/now/table/sys_user_group?sysparm_query=nameLIKE${q}^active=true&sysparm_limit=10&sysparm_fields=name,sys_id"
    ;;
  ci)
    q="${1:?name fragment required}"
    api GET "/api/now/table/cmdb_ci?sysparm_query=nameLIKE${q}^operational_status=1&sysparm_limit=10&sysparm_fields=name,sys_id,sys_class_name"
    ;;
  user)
    q="${1:?name fragment or user_name required}"
    api GET "/api/now/table/sys_user?sysparm_query=nameLIKE${q}^ORuser_nameLIKE${q}^active=true&sysparm_limit=10&sysparm_fields=user_name,name,sys_id,email"
    ;;
  raw)
    api "${1:?method}" "${2:?path}" "${3:-}"
    ;;
  *)
    cat >&2 <<'USAGE'
usage: snow.sh [--env dev|test|prod] <cmd> [args...]

Read:
  whoami                        Verify auth and show identity
  get <id>                      Read a change (id = CHG number or sys_id)
  list [n]                      Recent normal changes (default 5)
  mine [n]                      Normal changes opened by current API user
  group <name-fragment>         Lookup assignment_group sys_id
  ci <name-fragment>            Lookup cmdb_ci sys_id
  user <name-or-username>       Lookup sys_user sys_id

Write (refused against --env prod unless SNOW_PROD_WRITE_OK=1):
  create '<json>'               POST a new change_request
  update <id> '<json>'          PATCH fields on a change
  transition <id> <state>       Shortcut to PATCH only `state`

Escape hatch:
  raw <METHOD> <path> [json]    Arbitrary call against the instance
USAGE
    exit 2 ;;
esac
