---
description: Wire panma-hud into the user's Claude Code statusLine setting.
---

You are installing the panma-hud statusline into the user's Claude Code settings. The plugin only ships a script; Claude Code requires the user (or you, with their permission) to point `statusLine.command` at it. Follow this protocol precisely.

## 1. Locate the script

The statusline script lives inside this plugin at `statusline/panma-hud.sh`. Claude Code installs plugins under `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`, so the most portable command is a one-line bash wrapper that picks the highest-versioned install at runtime:

```
bash -c 'exec "$(ls -d ~/.claude/plugins/cache/*/panma-hud/*/statusline/panma-hud.sh 2>/dev/null | sort -V | tail -1)"'
```

Why not `${CLAUDE_PLUGIN_ROOT}/statusline/panma-hud.sh`? That env var is only set when Claude Code runs hooks/commands defined **by the plugin itself**. A user-level `statusLine.command` is not plugin-scoped, so `${CLAUDE_PLUGIN_ROOT}` expands to empty there and the script never runs. The wrapper above sidesteps that and also survives plugin version bumps without a hard-coded path.

## 2. Pick the settings file

Default to **user settings** (`~/.claude/settings.json`) so the HUD applies to every project. Only use project settings (`.claude/settings.json` in the cwd) if the user explicitly says they want it scoped to this one repo.

If the chosen file does not exist yet, create it as `{}`.

## 3. Show the change before writing

Read the chosen settings file and propose the merged result to the user. The target shape is:

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

Merge rules:
- If `statusLine` is absent → add the block above.
- If `statusLine` already exists and points to a different command → show both and ask which to keep. Never silently overwrite.
- If `statusLine` already points to `panma-hud.sh` → report "already installed" and exit.
- Preserve all other top-level keys exactly.

Display the resulting diff (compact JSON is fine) and ask the user to confirm before writing.

## 4. Write, then verify

On confirmation:
1. Write the merged JSON back to the chosen settings file with two-space indentation, preserving trailing newline.
2. Run the script once with a stub payload to prove it works end-to-end, e.g.:
   ```bash
   echo '{"model":{"display_name":"test"},"workspace":{"current_dir":"'"$PWD"'"}}' \
     | bash -c 'exec "$(ls -d ~/.claude/plugins/cache/*/panma-hud/*/statusline/panma-hud.sh 2>/dev/null | sort -V | tail -1)"'
   ```
   Show the user the output. If `jq` and `python3` are both missing, the script will say so — surface that and tell them to install one.
3. Tell the user the HUD will appear on the next assistant message (or after `/clear`); a full Claude Code restart is not required.

## 5. If anything is off

- The user may keep an existing statusline they like. In that case, do not install — just print the `command` line they'd need to add manually and exit.
- Do not modify other settings (hooks, env, permissions). Scope is `statusLine` only.
