#!/usr/bin/env bash
# panma-hud — Claude Code statusline
#
# Reads the JSON payload Claude Code sends on stdin and prints:
#   line 1: session summary  (model · cwd · ctx% · 5h% · 7d%)
#   line 2: harness snapshot (phase · workers · retries · STOP)  — only if .harness/state.json exists in cwd
#
# The 5h / 7d chips call Anthropic's OAuth usage endpoint
# (api.anthropic.com/api/oauth/usage) using the access token in
# ~/.claude/.credentials.json, then render utilization% and time until reset.
# Responses are cached for 30s in $TMPDIR to keep the 2s statusline refresh
# from hammering the endpoint. If no credentials exist (e.g. you're not
# signed into a subscription plan), the chips are simply omitted.
#
# Requires: bash + one JSON parser (jq preferred, falls back to python3) + curl.
# Wire it up via your user settings.json:
#   "statusLine": { "type": "command", "command": "<absolute path to this script>", "padding": 1, "refreshInterval": 2 }

set -u

# --- pick a JSON parser ---------------------------------------------------
# We expose two functions:
#   payload_get <jq-expr>          → field from stdin payload
#   state_get   <jq-expr> <file>   → field from a state.json file on disk
# Both print empty string when the field is absent or invalid.

if command -v jq >/dev/null 2>&1; then
  PARSER=jq
elif command -v python3 >/dev/null 2>&1; then
  PARSER=python3
else
  printf '\033[31m[panma-hud] needs jq or python3 — install one to enable the HUD\033[0m\n'
  exit 0
fi

PAYLOAD="$(cat 2>/dev/null || true)"
[ -z "$PAYLOAD" ] && PAYLOAD='{}'

if [ "$PARSER" = jq ]; then
  payload_get() { printf '%s' "$PAYLOAD" | jq -r "($1) // empty" 2>/dev/null; }
  state_validate() { jq -e . "$1" >/dev/null 2>&1; }
  state_get() { jq -r "($1) // empty" "$2" 2>/dev/null; }
else
  # python3 fallback. The expression syntax is a tiny dotted-path DSL, NOT jq.
  # Supported: ".a.b", ".a.b // 0", ".a.b // empty", "(.a // []) | length".
  _py_eval='
import json, sys, re
src = sys.argv[1]; expr = sys.argv[2]
try:
    data = json.loads(src) if src.strip() else {}
except Exception:
    print(""); sys.exit(0)

m = re.match(r"^\s*\((.+?)\s*//\s*\[\]\)\s*\|\s*length\s*$", expr)
length_mode = bool(m)
if length_mode:
    expr = m.group(1)

default = ""
m2 = re.match(r"^(.+?)\s*//\s*(.+)$", expr)
if m2:
    expr, dflt = m2.group(1).strip(), m2.group(2).strip()
    if dflt == "empty": default = ""
    elif dflt == "[]":  default = []
    else:
        try: default = int(dflt)
        except: default = dflt

cur = data
ok = True
for part in [p for p in expr.strip().lstrip(".").split(".") if p]:
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        ok = False; break
if not ok or cur is None:
    cur = default
if length_mode:
    try: print(len(cur))
    except: print(0)
else:
    if isinstance(cur, (dict, list)):
        print(json.dumps(cur))
    elif isinstance(cur, bool):
        print("true" if cur else "false")
    else:
        print(cur)
'
  payload_get() { python3 -c "$_py_eval" "$PAYLOAD" "$1" 2>/dev/null; }
  state_validate() { python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$1" >/dev/null 2>&1; }
  state_get() {
    local expr="$1" file="$2"
    python3 -c "$_py_eval" "$(cat "$file" 2>/dev/null)" "$expr" 2>/dev/null
  }
fi

# --- gather session fields -----------------------------------------------
model_name="$(payload_get '.model.display_name')"
[ -z "$model_name" ] && model_name="$(payload_get '.model.id')"
[ -z "$model_name" ] && model_name="?"
# Trim parenthetical suffix (e.g. "Opus 4.7 (1M context)" → "Opus 4.7")
model_name="${model_name%% (*}"

cwd="$(payload_get '.workspace.current_dir')"
[ -z "$cwd" ] && cwd="$(payload_get '.cwd')"
[ -z "$cwd" ] && cwd="$PWD"
cwd_short="$(basename "$cwd")"

ctx_pct="$(payload_get '.context_window.used_percentage')"

# --- usage chips: 5h / 7d utilization from Anthropic OAuth API -----------
# Cached in $TMPDIR for 30s. If credentials or curl are missing, the chips
# are simply omitted so the HUD still works on plain API-key setups.
usage_5h_pct=""
usage_5h_reset=""
usage_7d_pct=""
usage_7d_reset=""

CRED="$HOME/.claude/.credentials.json"
USAGE_CACHE="${TMPDIR:-/tmp}/panma-hud-usage-$(id -u 2>/dev/null || echo 0).json"
USAGE_TTL=30

if [ -f "$CRED" ] && command -v curl >/dev/null 2>&1; then
  now_ts=$(date +%s)
  cache_mtime=0
  [ -s "$USAGE_CACHE" ] && cache_mtime=$(stat -c %Y "$USAGE_CACHE" 2>/dev/null || stat -f %m "$USAGE_CACHE" 2>/dev/null || echo 0)
  if [ "$((now_ts - cache_mtime))" -ge "$USAGE_TTL" ]; then
    if [ "$PARSER" = jq ]; then
      _tok="$(jq -r '.claudeAiOauth.accessToken // empty' "$CRED" 2>/dev/null)"
    else
      _tok="$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("claudeAiOauth",{}).get("accessToken",""))
except: pass' "$CRED" 2>/dev/null)"
    fi
    if [ -n "$_tok" ]; then
      _resp="$(curl -sS -m 5 \
        -H "Authorization: Bearer $_tok" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "Content-Type: application/json" \
        https://api.anthropic.com/api/oauth/usage 2>/dev/null)"
      if [ -n "$_resp" ] && printf '%s' "$_resp" | grep -q '"five_hour"\|"seven_day"'; then
        umask 077
        printf '%s' "$_resp" > "$USAGE_CACHE.tmp" 2>/dev/null && mv "$USAGE_CACHE.tmp" "$USAGE_CACHE" 2>/dev/null
      fi
    fi
    unset _tok _resp
  fi

  if [ -s "$USAGE_CACHE" ]; then
    if [ "$PARSER" = jq ]; then
      usage_5h_pct="$(jq -r '.five_hour.utilization // empty' "$USAGE_CACHE" 2>/dev/null)"
      usage_5h_reset="$(jq -r '.five_hour.resets_at // empty' "$USAGE_CACHE" 2>/dev/null)"
      usage_7d_pct="$(jq -r '.seven_day.utilization // empty' "$USAGE_CACHE" 2>/dev/null)"
      usage_7d_reset="$(jq -r '.seven_day.resets_at // empty' "$USAGE_CACHE" 2>/dev/null)"
    else
      _usage_lines="$(python3 -c '
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception: d = {}
for k in ("five_hour","seven_day"):
    v = d.get(k) or {}
    print(v.get("utilization") if v.get("utilization") is not None else "")
    print(v.get("resets_at") or "")
' "$USAGE_CACHE" 2>/dev/null)"
      usage_5h_pct="$(printf '%s\n' "$_usage_lines" | sed -n '1p')"
      usage_5h_reset="$(printf '%s\n' "$_usage_lines" | sed -n '2p')"
      usage_7d_pct="$(printf '%s\n' "$_usage_lines" | sed -n '3p')"
      usage_7d_reset="$(printf '%s\n' "$_usage_lines" | sed -n '4p')"
      unset _usage_lines
    fi
  fi
fi

# Format an ISO-8601 reset timestamp as "Nd Nh" / "Nh Nm" / "Nm"
fmt_reset() {
  local iso="$1" target now diff d h m
  [ -z "$iso" ] && return
  target=$(date -d "$iso" +%s 2>/dev/null) || return
  now=$(date +%s)
  diff=$((target - now))
  [ "$diff" -le 0 ] && { printf 'reset'; return; }
  d=$((diff / 86400)); h=$(((diff % 86400) / 3600)); m=$(((diff % 3600) / 60))
  if   [ "$d" -gt 0 ]; then printf '%dd %dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh %dm' "$h" "$m"
  else                      printf '%dm' "$m"
  fi
}

# --- line 1: session summary ---------------------------------------------
CYAN='\033[36m'; DIM='\033[2m'; YEL='\033[33m'; RED='\033[31m'; GRN='\033[32m'
MAG='\033[35m'; BOLD='\033[1m'; RST='\033[0m'

line1="${CYAN}${model_name}${RST}${DIM} · ${RST}${cwd_short}"

if [ -n "$ctx_pct" ]; then
  ctx_int=$(printf '%.0f' "$ctx_pct" 2>/dev/null || echo 0)
  ctx_col="$GRN"
  [ "$ctx_int" -ge 70 ] 2>/dev/null && ctx_col="$YEL"
  [ "$ctx_int" -ge 90 ] 2>/dev/null && ctx_col="$RED"
  line1="${line1}${DIM} · ${RST}${ctx_col}ctx ${ctx_int}%${RST}"
fi

render_usage_chip() {
  local label="$1" pct="$2" reset_iso="$3" pct_int col rs
  [ -z "$pct" ] && return
  pct_int=$(printf '%.0f' "$pct" 2>/dev/null) || pct_int=0
  col="$GRN"
  [ "$pct_int" -ge 70 ] 2>/dev/null && col="$YEL"
  [ "$pct_int" -ge 90 ] 2>/dev/null && col="$RED"
  rs="$(fmt_reset "$reset_iso")"
  if [ -n "$rs" ]; then
    printf '%b%s:%d%%%b(%s)' "$col" "$label" "$pct_int" "$RST" "$rs"
  else
    printf '%b%s:%d%%%b' "$col" "$label" "$pct_int" "$RST"
  fi
}

if [ -n "$usage_5h_pct" ]; then
  chip="$(render_usage_chip 5h "$usage_5h_pct" "$usage_5h_reset")"
  line1="${line1}${DIM} · ${RST}${chip}"
fi
if [ -n "$usage_7d_pct" ]; then
  chip="$(render_usage_chip 7d "$usage_7d_pct" "$usage_7d_reset")"
  line1="${line1}${DIM} · ${RST}${chip}"
fi

printf '%b\n' "$line1"

# --- line 2: harness snapshot (conditional) ------------------------------
state_file="${cwd}/.harness/state.json"
stop_file="${cwd}/.harness/STOP"

if [ ! -f "$state_file" ]; then
  exit 0
fi

if ! state_validate "$state_file"; then
  printf '%b\n' "${DIM}harness:${RST} ${RED}state.json corrupt${RST}"
  exit 0
fi

cycle="$(state_get '.cycle_id' "$state_file")"
phase="$(state_get '.phase' "$state_file")"
retry="$(state_get '.retry_count // 0' "$state_file")"
retry_limit="$(state_get '.retry_limit // 0' "$state_file")"
active_n="$(state_get '(.active_workers // []) | length' "$state_file")"
done_n="$(state_get '(.completed_workers // []) | length' "$state_file")"
pending_n="$(state_get '(.pending_specs // []) | length' "$state_file")"
termination="$(state_get '.termination_reason' "$state_file")"

# Phase color
case "$phase" in
  designing)  phase_col="$MAG" ;;
  executing)  phase_col="$CYAN" ;;
  verifying)  phase_col="$YEL" ;;
  finalizing) phase_col="$YEL" ;;
  complete)   phase_col="$GRN" ;;
  needs_user) phase_col="$RED" ;;
  *)          phase_col="$DIM" ;;
esac

line2="${DIM}harness#${cycle:-?}${RST} ${phase_col}${BOLD}${phase:-?}${RST}"

if [ "${active_n:-0}" != "0" ] || [ "${done_n:-0}" != "0" ] || [ "${pending_n:-0}" != "0" ]; then
  workers_chip="${active_n:-0}↻/${done_n:-0}✓"
  [ "${pending_n:-0}" != "0" ] && workers_chip="${workers_chip} +${pending_n}q"
  line2="${line2}${DIM} · ${RST}${workers_chip}"
fi

if [ -n "${retry_limit:-}" ] && [ "$retry_limit" != "0" ]; then
  retry_col="$DIM"
  if [ "${retry:-0}" -gt 0 ] 2>/dev/null; then
    retry_col="$YEL"
    [ "$retry" -ge "$retry_limit" ] 2>/dev/null && retry_col="$RED"
  fi
  line2="${line2}${DIM} · ${RST}${retry_col}retry ${retry}/${retry_limit}${RST}"
fi

if [ -n "$termination" ]; then
  case "$termination" in
    success) term_col="$GRN" ;;
    *)       term_col="$RED" ;;
  esac
  line2="${line2}${DIM} · ${RST}${term_col}${termination}${RST}"
fi

if [ -f "$stop_file" ]; then
  line2="${line2}${DIM} · ${RST}${RED}${BOLD}■ STOP${RST}"
fi

printf '%b\n' "$line2"
