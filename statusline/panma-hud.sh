#!/usr/bin/env bash
# panma-hud — Claude Code statusline
#
# Reads the JSON payload Claude Code sends on stdin and prints:
#   line 1:  session summary  (model · "session name" · ctx%(⚠ 200k+) · 5h% · 7d%)
#   line 2:  harness snapshot (phase · workers · retries · STOP)         — only if .harness/state.json exists in cwd
#   line 3+: one indented line per active worker (domain · elapsed)      — only when active_workers ≥ 1
#
# Claude Code already ships rate-limit utilization for the active OAuth
# session inside the stdin payload (`.rate_limits.{five_hour,seven_day}`),
# so the 5h / 7d chips just read those fields. No API calls, no caching,
# no credentials handling — when the user is on a plain API-key setup the
# fields are absent and the chips are silently skipped.
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
# Trim parenthetical suffix (e.g. "Opus 4.7 (1M context)" → "Opus 4.7")
model_name="${model_name%% (*}"

# cwd is still needed below for resolving .harness/state.json, but is no longer
# displayed on line 1 (the basename chip was visual noise).
cwd="$(payload_get '.workspace.current_dir')"
[ -z "$cwd" ] && cwd="$(payload_get '.cwd')"
[ -z "$cwd" ] && cwd="$PWD"

ctx_pct="$(payload_get '.context_window.used_percentage')"
session_name="$(payload_get '.session_name')"
exceeds_200k="$(payload_get '.exceeds_200k_tokens')"

# panma-harness sidecar title override. The harness plugin instructs the main
# Claude to write a ≤15-char Korean summary of each request to a per-session
# sidecar in $TMPDIR; if present, it takes precedence over the payload's
# session_name (which is only set by --name or /rename). Falls through silently
# when the file isn't there (no panma-harness installed, no write yet, etc.).
session_id="$(payload_get '.session_id')"
if [ -n "$session_id" ]; then
  sid_safe="$(printf '%s' "$session_id" | tr -c 'A-Za-z0-9._-' '_')"
  sidecar="${TMPDIR:-/tmp}/panma-harness-title-${sid_safe}.txt"
  if [ -s "$sidecar" ]; then
    sidecar_title="$(head -1 "$sidecar" 2>/dev/null | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -n "$sidecar_title" ] && session_name="$sidecar_title"
  fi
fi

# --- usage chips: 5h / 7d utilization from the payload -------------------
# Claude Code's stdin payload already includes .rate_limits.{five_hour,seven_day}
# for OAuth sessions (resets_at is a Unix epoch). On plain API-key sessions
# these fields are absent, in which case the chips are silently omitted.
usage_5h_pct="$(payload_get '.rate_limits.five_hour.used_percentage')"
usage_5h_reset="$(payload_get '.rate_limits.five_hour.resets_at')"
usage_7d_pct="$(payload_get '.rate_limits.seven_day.used_percentage')"
usage_7d_reset="$(payload_get '.rate_limits.seven_day.resets_at')"

# Format a Unix-epoch (or ISO) reset timestamp as "Nd Nh" / "Nh Nm" / "Nm"
fmt_reset() {
  local ts="$1" target now diff d h m
  [ -z "$ts" ] && return
  if printf '%s' "$ts" | grep -qE '^[0-9]+$'; then
    target=$ts
  else
    target=$(date -d "$ts" +%s 2>/dev/null) || return
  fi
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

line1="${CYAN}${model_name}${RST}"

if [ -n "$session_name" ]; then
  # Truncate to 30 chars so a verbose title doesn't push the quota chips off-screen
  if [ "${#session_name}" -gt 30 ]; then
    session_short="${session_name:0:29}…"
  else
    session_short="$session_name"
  fi
  line1="${line1}${DIM} · \"${session_short}\"${RST}"
fi

if [ -n "$ctx_pct" ]; then
  ctx_int=$(printf '%.0f' "$ctx_pct" 2>/dev/null || echo 0)
  ctx_col="$GRN"
  [ "$ctx_int" -ge 70 ] 2>/dev/null && ctx_col="$YEL"
  [ "$ctx_int" -ge 90 ] 2>/dev/null && ctx_col="$RED"
  line1="${line1}${DIM} · ${RST}${ctx_col}ctx ${ctx_int}%${RST}"
  # Long-context pricing kicks in when the request's input exceeds 200k tokens.
  # Inline the warning into the ctx chip so the user sees it where they're
  # already reading the context number, rather than as a separate chip.
  if [ "$exceeds_200k" = "true" ]; then
    line1="${line1}${RED}${BOLD}(⚠ 200k+)${RST}"
  fi
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

# --- line 3+: one indented line per active worker ------------------------
# Each entry shows the worker's domain (or executor as fallback) plus elapsed
# time since started_at. Skipped entirely when there are no active workers.

list_workers() {
  if [ "$PARSER" = jq ]; then
    jq -r '(.active_workers // []) | .[] | [.domain // .executor // "?", .started_at // ""] | @tsv' \
      "$state_file" 2>/dev/null
  else
    python3 -c '
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
for w in (d.get("active_workers") or []):
    name = w.get("domain") or w.get("executor") or "?"
    started = w.get("started_at") or ""
    print(f"{name}\t{started}")
' "$state_file" 2>/dev/null
  fi
}

fmt_elapsed() {
  local started="$1" started_s diff h m s
  [ -z "$started" ] && return
  started_s=$(date -d "$started" +%s 2>/dev/null) || return
  diff=$(( $(date +%s) - started_s ))
  [ "$diff" -lt 0 ] && diff=0
  if   [ "$diff" -ge 3600 ]; then
    h=$((diff / 3600)); m=$(((diff % 3600) / 60))
    printf '%dh %dm' "$h" "$m"
  elif [ "$diff" -ge 60 ]; then
    m=$((diff / 60)); s=$((diff % 60))
    printf '%dm %ds' "$m" "$s"
  else
    printf '%ds' "$diff"
  fi
}

while IFS=$'\t' read -r w_name w_started; do
  [ -z "$w_name" ] && continue
  elapsed="$(fmt_elapsed "$w_started")"
  if [ -n "$elapsed" ]; then
    printf '%b  ↳ %b%s%b %b(%s)%b\n' "$DIM" "$CYAN" "$w_name" "$RST" "$DIM" "$elapsed" "$RST"
  else
    printf '%b  ↳ %b%s%b\n' "$DIM" "$CYAN" "$w_name" "$RST"
  fi
done < <(list_workers)
