---
name: fleet-features
description: Lists every opt-in/opt-out feature flag across the marketplace (fleet-controller, ticket-auto-pipeline, ticket-planner) with a plain explanation, shows whether each is enabled on this host and where the value comes from (env, fleet-start.sh, settings.local.json, or default), and recommends which to turn on and in what order, respecting prerequisites. Read-only. Use when the user asks "what features am I not using", "which flags should I enable", "what does FLEET_X do", or "/fleet-features".
allowed-tools: Bash
---

# Fleet Features

Features in this marketplace ship behind flags, most of them off by default. This skill shows what each flag does, whether it is on here, and which ones are worth turning on.

**Determinism boundary.** `lib/fleet-features.sh` does the inventory and resolves the values. It reads the catalog `fleet-controller/features.json` and parses the workspace files as text. You only present the result and recommend. Never guess a flag's value or default from memory. If the script's JSON does not say it, you do not know it.

## Usage

```
/fleet-features [--workspace DIR]
```

`DIR` is the tickets workspace that holds `fleet-start.sh` and `.claude/settings.local.json`. When it is not given, the script uses `$FLEETD_WORKSPACE`, then the current directory.

## Execution

### Step 1: Run the inventory

Find the installed script the same way `/fleet-env-check` does (installed version first, then the newest cache version, then `$CLAUDE_PLUGIN_ROOT`). Write the JSON to a temp file, so the output does not get truncated.

```bash
rm -f /tmp/fleet-features-output.json
FEATURES_SH=""
FEATURES_SH="$(sed -n 's/.*"installPath"[[:space:]]*:[[:space:]]*"\([^"]*\/fleet-controller\/[^"]*\)".*/\1/p' \
  "${HOME}/.claude/plugins/installed_plugins.json" 2>/dev/null | sort -V | tail -1)/lib/fleet-features.sh"
[ -f "$FEATURES_SH" ] || FEATURES_SH=$(find "${HOME}/.claude/plugins/cache" \
  -path "*/fleet-controller/*/lib/fleet-features.sh" 2>/dev/null | sort -V | tail -1)
[ -f "$FEATURES_SH" ] || FEATURES_SH=""
if [ -z "$FEATURES_SH" ] && [ -f "$CLAUDE_PLUGIN_ROOT/lib/fleet-features.sh" ]; then
  FEATURES_SH="$CLAUDE_PLUGIN_ROOT/lib/fleet-features.sh"
fi
if [ -n "$FEATURES_SH" ]; then
  # Pass --workspace DIR here when the user gave one.
  bash "$FEATURES_SH" --json >/tmp/fleet-features-output.json || echo "fleet-features.sh failed (exit $?)"
else
  echo "fleet-features.sh not found — reinstall the fleet-controller plugin"
fi
```

```bash
[ -s /tmp/fleet-features-output.json ] && cat /tmp/fleet-features-output.json || echo "OUTPUT_FILE_MISSING"
```

The output is one JSON object: `workspace`, `catalog`, `sources` (which layers were found), `count`, and `flags[]`. Each flag has `name`, `plugin`, `category`, `value`, `source`, `default`, `enabled`, `recommend`, `summary`, `why`, `docs`, `requires[]`, `requires_met` (`true`, `false`, or `null` when only manual steps apply), `unmet[]` and `manual_steps[]`.

**Process environment caveat.** The `env` source is this Claude Code session's own environment. That is the right view for interactive planner and ticket-auto sessions, because Claude Code loads `settings.local.json`'s `env` into it. fleetd workers get their environment from `fleet-start.sh` instead. If the user asks "what does fleetd run with", run the script again with `--no-env` and use that result for fleetd-side flags.

**Secrets.** The script masks any value whose name matches `KEY|TOKEN|SECRET|PASS|HEADERS`, and it reports prerequisite credentials only as met or unmet. Do not read `settings.local.json` or `fleet-start.sh` yourself to fill in values.

### Step 2: Present in groups

Render these groups in this order. Use one short table or list per group. Leave out a group that is empty. Every flag appears in exactly one group.

1. **Already on.** `enabled == true`. Columns: name, what it gives you (`summary`), source. Flag a problem in bold when `requires_met == false`. A flag that is on with an unmet prerequisite usually does nothing (for example `FLEET_SCORE_EXPORT_ENABLE` without Langfuse credentials). Name the missing items from `unmet`.
2. **Off, recommended.** `enabled == false`, `recommend == "on"`. For each: `summary`, `why`, and the prerequisites (`unmet` plus `manual_steps`). Order them by dependency: a flag that another flag in this list needs comes first. For example, `FLEETD_SPAWN_ENABLED` comes before `FLEET_AUTO_RESTART`, and the board-cursor fast-forward step comes before `FLEET_BOARD_PUSHER_ENABLE`. Quote `manual_steps` exactly. Some of them, like the fast-forward, cause visible damage if they are skipped.
3. **Off, situational.** `enabled == false`, `recommend == "situational"`, `category` not `strictness`. Give one line each: `summary`, then "turn on if ..." from `why`. Show its prerequisites.
4. **Strictness knobs.** `category == "strictness"`, on or off. Explain the trade-off once, above the list: each one makes more tickets get held as not-ready, so a person must fix the ticket before it runs. Turn them on when tickets that reach implement are too vague. Leave them off while held tickets would only pile up. Then give one line per flag with its current state.
5. **Leave alone.** `category` is `intentional-off`, `debug-escape-hatch`, or `safety` and the flag is at its recommended state. One line each. For a `safety` flag that is **off**, or a debug flag that is **on**, move it to the top of the whole report as a warning.

After the groups, state "N flags from <catalog>". N is `count`.

### Step 3: Suggest concrete edits

End with a short list of the exact lines to add. Base it only on the flags you recommended in Step 2 and their unmet prerequisites:

- **fleetd-side flags** (plugin `fleet-controller`, plus `POSTMORTEM_*` when fleetd runs the pipelines): add `export NAME=value` to `<workspace>/fleet-start.sh`, then restart fleetd. Use `on_value` for the value. It is `1` for `FLEETD_SPAWN_ENABLED` and `true` for most others.
- **Interactive-session flags** (plugin `ticket-planner`, and `ticket-auto-pipeline` flags for hand-run `/ticket-auto` sessions): add `"NAME": "value"` under `env` in `<workspace>/.claude/settings.local.json`, then start a new Claude Code session.
- Put every manual step before the flag that needs it.
- A flag already set in one file may also need to be set in the other, when both fleetd and interactive sessions need it. Say so.

**Do NOT edit any file.** This skill is read-only. Only write a change when the user asks for it in a later message, and then change only the lines they approved.
