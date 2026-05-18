# panma-hud

Multi-line heads-up display for Claude Code, surfaced through the `statusLine` setting.

```
Opus 4.7 · my-repo · "Add new feature" · ctx:42% · 5h:11%(3h 39m) · wk:6%(10h 39m) · +168/−57
harness#3 executing · 3↻/1✓ +1q · retry 1/5
  ↳ db (2m 31s)
  ↳ backend (1m 13s)
  ↳ frontend (46s)
```

- **Line 1** — model · cwd basename · AI-generated session name · context window % · 5h quota · weekly quota · session diff stats (+added / −removed).
- **Line 2** — appears only when `.harness/state.json` exists in the cwd: cycle id, phase, active/completed workers (+queue depth), retry budget, termination reason, and a red `■ STOP` if `.harness/STOP` is present.
- **Line 3+** — one indented line per active harness worker (domain + elapsed time), only when there are active workers. Skipped entirely otherwise.

The model name has any parenthetical suffix stripped (e.g. `Opus 4.7 (1M context)` → `Opus 4.7`). Session names longer than 30 characters are truncated with an ellipsis so a verbose title doesn't push the quota chips off-screen. The quota chips read `.rate_limits.{five_hour,seven_day}` directly from the statusline payload that Claude Code already provides on OAuth sessions, so there are no extra API calls or credentials to manage. On plain API-key setups those fields are absent and the chips are silently omitted.

Pairs with [panma-harness](https://github.com/panma-claude/harness), but the session-summary line is useful on its own in any project.

## Install

From the panma marketplace:

```
/plugin marketplace add panma-claude/marketplace
/plugin install panma-hud
```

Then wire it into your statusline:

```
/hud-install
```

`/hud-install` proposes a merge into `~/.claude/settings.json` and writes it after you confirm. If you'd rather do it by hand, add this:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash -c 'exec \"$(ls -d ~/.claude/plugins/cache/*/panma-hud/*/statusline/panma-hud.sh 2>/dev/null | sort -V | tail -1)\"'",
    "padding": 1,
    "refreshInterval": 2
  }
}
```

> Note: `${CLAUDE_PLUGIN_ROOT}` is only set for hooks/commands that the plugin itself defines — it doesn't expand inside a user-level `statusLine.command`. The wrapper above resolves the highest-versioned installed cache directory at runtime.

The HUD appears on the next assistant message (or after `/clear`).

## Requirements

- `bash`
- One JSON parser: `jq` (preferred) or `python3`. If neither is on `PATH`, the HUD prints a one-line install hint instead of garbage.

## How the harness line works

`panma-hud` reads `<cwd>/.harness/state.json` on every statusline refresh and treats it as the single source of truth. It does not invoke Claude, does not call subagents, and does not write anywhere. If the file is missing, the second line is omitted entirely. If the file is corrupt, it prints `harness: state.json corrupt` and stops.

Phase colors:

| phase | color |
|---|---|
| `designing` | magenta |
| `executing` | cyan |
| `verifying` / `finalizing` | yellow |
| `complete` | green |
| `needs_user` | red |

Retry chip turns yellow once any retry is consumed and red when the budget is exhausted. Termination reason is shown only after the cycle ends — green for `success`, red for anything else.

## Uninstall

```
/plugin remove panma-hud
```

Then remove the `statusLine` block from your `settings.json` (the plugin only ships the script; the wiring is yours).
