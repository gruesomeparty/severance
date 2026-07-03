---
name: configuring-severance
description: Configure the Severance budget gate for this repository. Use whenever the user mentions severance, budget gates, usage limits for side projects, stopping Claude Code before extra spending, or auto-resume after limit resets — even if they don't name the plugin.
---

# Configuring Severance for this repository

Severance hard-caps a side project's Claude Code spend so it can't roll into
usage-credit billing, then auto-resumes it when the usage window resets. Work
this checklist top to bottom. Ask the user for their intent only where noted.

## 1. Confirm the plugin is installed

```
claude plugin list
```

If `severance` is not listed, add the marketplace and install it:

```
/plugin marketplace add gruesomeparty/severance
/plugin install severance@severance
```

(Installing the plugin alone changes nothing — every project is opt-in.)

## 2. Decide the priority, then write the project env block

Ask the user how much this project matters if you can't infer it:

- **work repo** → `critical` (utilization gates off; only an absolute cost cap
  or credit-burn stops it — work is allowed to roll into org usage credits).
- **side project** → `high`, `normal` (default), or `low`.

The ladder decides *when* each priority trips (defaults, tunable in
`~/.claude/severance/config.json`):

| priority | 5h trip | 7d trip | reserve (preempts lower) |
|----------|--------:|--------:|-------------------------:|
| critical | off     | off     | off                      |
| high     | 85%     | 95%     | 60%                      |
| normal   | 70%     | 85%     | –                        |
| low      | 50%     | 70%     | –                        |

Write (merge, don't clobber) into the project's `.claude/settings.json`:

```json
{
  "env": {
    "SEVERANCE_ENABLED": "1",
    "SEVERANCE_PRIORITY": "normal"
  }
}
```

Optional overrides (only if the user asks): `SEVERANCE_UTIL_PCT`,
`SEVERANCE_WEEKLY_PCT` (override the ladder), `SEVERANCE_LIMIT_USD` (absolute
per-session cost cap, applies to every priority), `SEVERANCE_MAX_RESUMES`
(default 3), `SEVERANCE_ALLOW_EXTRA_USAGE=1` (disable the used-credits hard trip
— intended for `critical`/work only).

## 3. Set up the statusline bridge (once per user, in `~/.claude/settings.json`)

The bridge captures Anthropic's official `rate_limits` — the primary signal. It
delegates to any existing statusline, so it composes with the user's setup.

1. Find the installed bridge path (under the plugin cache), e.g.:
   ```
   ls "$(claude plugin list --json 2>/dev/null | jq -r '.[]|select(.name=="severance").path' 2>/dev/null)"/scripts/statusline-bridge.sh 2>/dev/null \
     || ls ~/.claude/plugins/*/severance*/plugin/scripts/statusline-bridge.sh 2>/dev/null
   ```
2. In `~/.claude/settings.json`, if `statusLine.command` is already set, move its
   current value into `env.SEVERANCE_INNER_STATUSLINE`, then point
   `statusLine.command` at the bridge:
   ```json
   {
     "statusLine": { "type": "command", "command": "/abs/path/to/statusline-bridge.sh" },
     "env": { "SEVERANCE_INNER_STATUSLINE": "<the previous statusLine command, or unset>" }
   }
   ```
   If there was no prior statusline, leave `SEVERANCE_INNER_STATUSLINE` unset —
   the bridge prints a compact default line.

If you cannot set the bridge, Severance still works via the OAuth fallback and
`ccusage` estimate — just less precisely. Tell the user.

## 4. Keep local state out of git

Add to the project `.gitignore` (handover + local state are per-machine):

```
.severance/
```

## 5. Verify

Run `/severance:severance-status` and report which signal tier is live
(`statusline` = best, `oauth` = fallback, `ccusage` = estimate) and the current
5h / 7d utilization. If the tier is `ccusage`, remind the user that Tier-1 needs
a recent Claude Code + Pro/Max login and the statusline bridge from step 3.
