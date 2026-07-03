# Architecture

Severance is two deliverables around one shared directory. **`~/.claude/severance/`
is the API** — plain JSON files, schema-validated in CI, written atomically under
a lock. Everything else is a producer or consumer of those files.

```
statusline (official rate_limits)          oauth endpoint (fallback)      ccusage (estimate)
        │                                          │                            │
        └──────────────► severance-lib normalizer ◄┴────────────────────────────┘
                                   │
                          ~/.claude/severance/usage.json
                                   │
        ┌──────────────────────────┼───────────────────────────┐
   gate.sh (PreToolUse/            │                     Severance.app
   SessionStart, exit 2)     projects/*.json ◄──────────  (reader + macOS
        │                          ▲                       resume scheduler)
   handover.md ◄─ agent            │                            │
        │                    heartbeat.sh (Stop)          tmux send-keys
   schedule-resume.sh (Linux, systemd-run) ────────► resume.sh ─┘
```

## Components

| Piece | Role |
|---|---|
| `statusline-bridge.sh` | Captures Tier-1 `rate_limits` from the statusline stdin → `usage.json`; delegates to the user's real statusline. |
| `oauth-usage.sh` | Tier-2 fallback: OAuth usage endpoint, cached, token via Keychain/creds file. |
| `severance-lib.sh` | Shared library: config/ladder resolution, the tier normalizer (`sev_acquire`/`sev_normalize`), atomic state I/O, portable lock, preemption. |
| `gate.sh` | PreToolUse (blocks with exit 2 + handover instruction) and SessionStart (`additionalContext`, D2) gate. |
| `heartbeat.sh` | Stop hook: refresh per-project cost/status each turn. |
| `resume.sh` / `schedule-resume.sh` | Return a severed project to its tmux pane; schedule that at window reset (systemd on Linux). |
| `Severance.app` | Read-only dashboard over the state dir + the macOS resume scheduler (replaces systemd). |

## Shared state (`~/.claude/severance/`)

- `usage.json` — signal snapshot; consumers read only the `normalized` block. Every
  snapshot records `signal_tier` (`statusline` > `oauth` > `ccusage`).
- `config.json` — the priority ladder + `resume_stagger_minutes`.
- `projects/<slug>.json` — per-project state (one file per opted-in project).

Contracts live in [`../schemas/`](../schemas); see [SIGNALS.md](SIGNALS.md) for
the tiers and [DEVIATIONS.md](DEVIATIONS.md) for where reality differs from the PRD.

## Project state machine

```
                 util/weekly/cost/extra_usage trip
        active ───────────────────────────────► severed ── window reset──► resume.sh
          ▲   ◄───────────── resume (pane alive) ────────────┘   │
          │                                                       └─ pane gone ─► orphaned
          └───────────────── (heartbeat keeps cost fresh) ───────────────────────
```

`paused` is **orthogonal**: a manual pause or a preemption (`reason: preempted`)
sets `paused: true` (status `paused`) without going through `severed`. The gate
trips on `paused` at the next tool call; the project returns to `active` when the
pause clears (resume, or the preemptor's reserve is no longer exceeded).

## Enforcement points

- **PreToolUse** is the real gate — it blocks the tool call (exit 2) and its stderr
  is the handover instruction. Writes into `.severance/` are whitelisted so the
  agent can comply.
- **SessionStart** cannot block on exit 2 (D2), so it only injects
  `additionalContext`; the first PreToolUse still enforces.
- **Preemption** (a high-priority session at/over its `reserve`) pauses enabled
  lower-priority projects, throttled once/60s (R5).
