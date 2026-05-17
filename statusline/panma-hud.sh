#!/usr/bin/env bash
# panma-hud — Claude Code statusline
#
# Reads the JSON payload Claude Code sends on stdin and prints:
#   line 1: session summary  (model · cwd · ctx% · tokens)
#   line 2: harness snapshot (phase · workers · retries · STOP)  — only if .harness/state.json exists in cwd
#
# The tokens chip sums every .message.usage entry in the session transcript
# (input + output + cache_creation + cache_read). On subscription plans the
# dollar figure Claude Code reports is theoretical anyway — total tokens is
# the more honest "what did this session actually consume" indicator.
#
# Requires: bash + one JSON parser (jq preferred, falls back to python3).
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

cwd="$(payload_get '.workspace.current_dir')"
[ -z "$cwd" ] && cwd="$(payload_get '.cwd')"
[ -z "$cwd" ] && cwd="$PWD"
cwd_short="$(basename "$cwd")"

ctx_pct="$(payload_get '.context_window.used_percentage')"
transcript_path="$(payload_get '.transcript_path')"

# --- tokens chip: sum .message.usage across the transcript ---------------
total_tokens=""
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  if [ "$PARSER" = jq ]; then
    total_tokens=$(jq -R 'fromjson? | .message.usage // empty
      | (.input_tokens // 0) + (.output_tokens // 0)
        + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)' \
      "$transcript_path" 2>/dev/null | awk '{s+=$1} END {print s+0}')
  else
    total_tokens=$(python3 -c '
import json, sys
total = 0
try:
    with open(sys.argv[1]) as f:
        for line in f:
            try:
                msg = json.loads(line).get("message")
                u = msg.get("usage") if isinstance(msg, dict) else None
                if isinstance(u, dict):
                    total += (u.get("input_tokens") or 0) + (u.get("output_tokens") or 0)
                    total += (u.get("cache_creation_input_tokens") or 0) + (u.get("cache_read_input_tokens") or 0)
            except Exception:
                continue
except Exception:
    pass
print(total)
' "$transcript_path" 2>/dev/null)
  fi
fi

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

if [ -n "$total_tokens" ] && [ "$total_tokens" != "0" ]; then
  tok_fmt=$(awk -v n="$total_tokens" 'BEGIN {
    if (n >= 1000000) printf "%.1fM", n/1000000;
    else if (n >= 1000)    printf "%.0fk", n/1000;
    else                   printf "%d", n;
  }')
  line1="${line1}${DIM} · ${RST}${tok_fmt} tok"
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
