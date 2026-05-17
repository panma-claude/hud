# panma-hud

Two-line heads-up display for Claude Code, surfaced through the `statusLine` setting.

```
Opus 4.7 · my-repo · ctx 42% · 184k tok
harness#3 executing · 2↻/1✓ +1q · retry 1/5
```

- **Line 1** — model · cwd basename · context window % · cumulative session tokens (input + output + cache_creation + cache_read, summed from the transcript)
- **Line 2** — appears only when `.harness/state.json` exists in the cwd: cycle id, phase, active/completed workers (+queue depth), retry budget, termination reason, and a red `■ STOP` if `.harness/STOP` is present

> The tokens chip is independent of plan: it's a literal count from the transcript, so it's a useful "quota burn" indicator on subscription plans where the dollar figure Claude Code emits is theoretical.

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
