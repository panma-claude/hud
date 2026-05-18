#!/usr/bin/env bash
# panma-hud — Claude Code statusline
#
# Reads the JSON payload Claude Code sends on stdin and prints:
#   line 1:  session summary  (model · "session name" · ctx:% · 5h% · wk%)
#   line 2:  harness snapshot (phase · workers · retries · STOP)         — only if .harness/state.json exists in cwd
#   line 3+: one indented line per active worker (domain · elapsed)      — only when active_workers ≥ 1
#
# Claude Code already ships rate-limit utilization for the active OAuth
# session inside the stdin payload (`.rate_limits.{five_hour,seven_day}`),
# so the 5h / wk chips just read those fields. No API calls, no caching,
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

# --- usage chips: 5h / wk utilization from the payload -------------------
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

# Format a past timestamp (Unix-epoch or ISO) as a single-unit "N{s,m,h,d}".
# Used by the last-cycle chip when no .harness/state.json is present.
fmt_ago() {
  local ts="$1" target now diff
  [ -z "$ts" ] && return
  if printf '%s' "$ts" | grep -qE '^[0-9]+$'; then
    target=$ts
  else
    target=$(date -d "$ts" +%s 2>/dev/null) || return
  fi
  now=$(date +%s)
  diff=$((now - target))
  [ "$diff" -lt 0 ] && diff=0
  if   [ "$diff" -lt 60 ];    then printf '%ds' "$diff"
  elif [ "$diff" -lt 3600 ];  then printf '%dm' "$((diff / 60))"
  elif [ "$diff" -lt 86400 ]; then printf '%dh' "$((diff / 3600))"
  else                              printf '%dd' "$((diff / 86400))"
  fi
}

# Format a raw integer duration (seconds) as compact "Ns" / "Nm Ns" / "Nh Nm".
fmt_elapsed_sec() {
  local s="$1"
  [ -z "$s" ] && { printf '0s'; return; }
  if   [ "$s" -ge 3600 ]; then printf '%dh %dm' "$((s / 3600))" "$(((s % 3600) / 60))"
  elif [ "$s" -ge 60 ];   then printf '%dm %ds' "$((s / 60))" "$((s % 60))"
  else                         printf '%ds' "$s"
  fi
}

# Format an ISO-8601 (or epoch) past timestamp as elapsed-since-then.
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
  line1="${line1}${DIM} · ${RST}\"${session_short}\""
fi

if [ -n "$ctx_pct" ]; then
  ctx_int=$(printf '%.0f' "$ctx_pct" 2>/dev/null || echo 0)
  ctx_col="$GRN"
  [ "$ctx_int" -ge 70 ] 2>/dev/null && ctx_col="$YEL"
  [ "$ctx_int" -ge 90 ] 2>/dev/null && ctx_col="$RED"
  line1="${line1}${DIM} · ${RST}${ctx_col}ctx:${ctx_int}%${RST}"
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
  chip="$(render_usage_chip wk "$usage_7d_pct" "$usage_7d_reset")"
  line1="${line1}${DIM} · ${RST}${chip}"
fi

printf '%b\n' "$line1"

# --- line 2: harness snapshot (conditional) ------------------------------
state_file="${cwd}/.harness/state.json"
stop_file="${cwd}/.harness/STOP"

if [ ! -f "$state_file" ]; then
  # Fallback: show the most recent archived cycle from .harness/history/INDEX.json
  # (panma-harness writes this on every termination, see harness-iterate.md §8).
  index_file="${cwd}/.harness/history/INDEX.json"
  if [ -f "$index_file" ] && state_validate "$index_file"; then
    if [ "$PARSER" = jq ]; then
      tsv="$(jq -r '
        (. // []) | if length == 0 then empty
        else .[-1] | [.verdict // "", .request // "", (.elapsed_sec // 0 | tostring), .finished_at // ""] | @tsv
        end
      ' "$index_file" 2>/dev/null)"
    else
      tsv="$(python3 -c '
import json, sys
try: arr = json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
if not isinstance(arr, list) or len(arr) == 0: sys.exit(0)
e = arr[-1]
print("\t".join([
  str(e.get("verdict") or ""),
  str(e.get("request") or ""),
  str(e.get("elapsed_sec") or 0),
  str(e.get("finished_at") or ""),
]))
' "$index_file" 2>/dev/null)"
    fi
    if [ -n "$tsv" ]; then
      IFS=$'\t' read -r l_verdict l_request l_elapsed l_finished <<< "$tsv"
      case "$l_verdict" in
        complete)   l_icon="✓"; l_col="$GRN" ;;
        needs_user) l_icon="✗"; l_col="$RED" ;;
        *)          l_icon="·"; l_col="$DIM" ;;
      esac
      # Truncate long requests so the chip fits in narrow terminals
      if [ "${#l_request}" -gt 40 ]; then
        l_request="${l_request:0:39}…"
      fi
      l_elapsed_chip="$(fmt_elapsed_sec "${l_elapsed:-0}")"
      l_ago_chip="$(fmt_ago "$l_finished")"
      [ -z "$l_ago_chip" ] && l_ago_chip="?"
      printf '%bharness · last:%b %b%s "%s"%b %b(%s, %s ago)%b\n' \
        "$DIM" "$RST" "$l_col" "$l_icon" "$l_request" "$RST" \
        "$DIM" "$l_elapsed_chip" "$l_ago_chip" "$RST"
    fi
  fi
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
cycle_started_at="$(state_get '.cycle_started_at' "$state_file")"

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
  retry_suffix=""
  if [ "${retry:-0}" -gt 0 ] 2>/dev/null; then
    retry_col="$YEL"
    [ "$retry" -ge "$retry_limit" ] 2>/dev/null && retry_col="$RED"
    # On re-plan (designer phase after a failure), make the marker explicit.
    if [ "$phase" = "designing" ]; then
      retry_suffix=" (replan)"
    fi
  fi
  line2="${line2}${DIM} · ${RST}${retry_col}retry ${retry}/${retry_limit}${retry_suffix}${RST}"
fi

# Cycle elapsed clock — visible whenever cycle_started_at is known.
if [ -n "$cycle_started_at" ]; then
  cycle_elapsed="$(fmt_elapsed "$cycle_started_at")"
  if [ -n "$cycle_elapsed" ]; then
    line2="${line2}${DIM} · ${cycle_elapsed}${RST}"
  fi
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

# --- line 3: phase detail (verifying / finalizing only) ------------------
# During verifying, list the dynamic checks the Verifier was told to run.
# During finalizing, rule-applier is running (V3 will replace this with a
# live progress line; for now we surface that the phase is active so the
# user knows the cycle is still working even though no executor workers
# are visible).

# Helper: parse a progress file ({current, started_at, completed[], total}) into
# tab-separated "<current>\t<started_at>\t<completed_count>\t<total>". Empty if
# the file is missing or invalid.
read_progress() {
  local pfile="$1"
  [ -f "$pfile" ] || return
  if [ "$PARSER" = jq ]; then
    jq -r '[.current // "", .started_at // "", ((.completed // []) | length | tostring), (.total // 0 | tostring)] | @tsv' \
      "$pfile" 2>/dev/null
  else
    python3 -c '
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
completed = d.get("completed") or []
print("\t".join([
  str(d.get("current") or ""),
  str(d.get("started_at") or ""),
  str(len(completed)),
  str(d.get("total") or 0),
]))
' "$pfile" 2>/dev/null
  fi
}

case "$phase" in
  verifying)
    # V3: prefer live progress from .harness/verifier-progress.json
    vprog="$(read_progress "${cwd}/.harness/verifier-progress.json")"
    if [ -n "$vprog" ]; then
      IFS=$'\t' read -r v_current v_started v_done v_total <<< "$vprog"
      v_elapsed="$(fmt_elapsed "$v_started")"
      v_position=$((v_done + 1))
      if [ -n "$v_elapsed" ]; then
        printf '%b  → verifier: %b%s%b %b(%s of %s · %s)%b\n' \
          "$DIM" "$YEL" "$v_current" "$RST" \
          "$DIM" "$v_position" "$v_total" "$v_elapsed" "$RST"
      else
        printf '%b  → verifier: %b%s%b %b(%s of %s)%b\n' \
          "$DIM" "$YEL" "$v_current" "$RST" \
          "$DIM" "$v_position" "$v_total" "$RST"
      fi
    else
      # V2 fallback: show the verification_spec from state.json
      if [ "$PARSER" = jq ]; then
        vspec="$(jq -r '(.verification_spec // []) | join("\t")' "$state_file" 2>/dev/null)"
      else
        vspec="$(python3 -c '
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
spec = d.get("verification_spec") or []
print("\t".join(str(x) for x in spec))
' "$state_file" 2>/dev/null)"
      fi
      if [ "$vspec" = "manual" ]; then
        printf '%b  → verifier: %bmanual%b %b(deferred to user)%b\n' \
          "$DIM" "$YEL" "$RST" "$DIM" "$RST"
      elif [ -n "$vspec" ]; then
        vspec_display="${vspec//$'\t'/, }"
        printf '%b  → verifier: %b%s%b\n' "$DIM" "$YEL" "$vspec_display" "$RST"
      fi
    fi
    ;;
  finalizing)
    # V3: prefer live progress from .harness/rule-applier-progress.json
    rprog="$(read_progress "${cwd}/.harness/rule-applier-progress.json")"
    if [ -n "$rprog" ]; then
      IFS=$'\t' read -r r_current r_started r_done r_total <<< "$rprog"
      r_elapsed="$(fmt_elapsed "$r_started")"
      r_position=$((r_done + 1))
      if [ -n "$r_elapsed" ]; then
        printf '%b  → rule-applier: %b%s%b %b(%s of %s · %s)%b\n' \
          "$DIM" "$YEL" "$r_current" "$RST" \
          "$DIM" "$r_position" "$r_total" "$r_elapsed" "$RST"
      else
        printf '%b  → rule-applier: %b%s%b %b(%s of %s)%b\n' \
          "$DIM" "$YEL" "$r_current" "$RST" \
          "$DIM" "$r_position" "$r_total" "$RST"
      fi
    else
      printf '%b  → rule-applier: review · security-review · post-finish%b\n' "$DIM" "$RST"
    fi
    ;;
esac

# --- line 4+: one indented line per active worker ------------------------
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

while IFS=$'\t' read -r w_name w_started; do
  [ -z "$w_name" ] && continue
  elapsed="$(fmt_elapsed "$w_started")"
  if [ -n "$elapsed" ]; then
    printf '%b  ↳ %b%s%b %b(%s)%b\n' "$DIM" "$CYAN" "$w_name" "$RST" "$DIM" "$elapsed" "$RST"
  else
    printf '%b  ↳ %b%s%b\n' "$DIM" "$CYAN" "$w_name" "$RST"
  fi
done < <(list_workers)
