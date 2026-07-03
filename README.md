# Severance

**Sever your side-project Claude Code spend from your work spend on a shared Team plan.**

> Your **outie** works unbudgeted — long sessions on the org's dime, allowed to
> roll into usage credits. Your **innie** gets a hard allowance and a scheduled
> return to the severed floor.

Severance is two deliverables in one repo:

1. A **Claude Code plugin** — hooks + a statusline bridge + scripts that gate
   opted-in ("severed") projects on Anthropic's *official* utilization
   accounting, instruct the agent to write a handover, stop the session before
   it can trigger usage-credit billing, and auto-resume it in its original tmux
   pane when the usage window resets.
2. A **macOS menu bar app** (`Severance.app`) — a read-only dashboard over the
   shared state directory, plus the macOS resume scheduler.

## Why

On a Team plan, work sessions may roll into organization usage credits (extra
billing) — fine for your outie. Side projects shouldn't. Severance gates severed
projects on Anthropic's own `rate_limits` accounting, so the gate keeps working
even when limits or model weightings change; it hard-stops them before the plan
limit; and it brings them back automatically at reset — "returning to the
severed floor."

Opt-in is explicit and per-project (`SEVERANCE_ENABLED=1` in a repo's
`.claude/settings.json`), so installing the plugin org-wide leaves work repos
untouched. All state is plain JSON under one directory; the menu bar app (or
`cat`) is just a reader.

## Quickstart (plugin)

```text
/plugin marketplace add gruesomeparty/severance
/plugin install severance@severance
```

Then, in a side project you want gated, add to `.claude/settings.json`:

```json
{ "env": { "SEVERANCE_ENABLED": "1", "SEVERANCE_PRIORITY": "normal" } }
```

and point your statusline at the bridge (see [docs/INSTALL.md](docs/INSTALL.md)).
The bundled `configuring-severance` skill automates all of this — just ask Claude
to *"set up severance for this repo."*

## Menu bar app (macOS)

`Severance.app` shows the 5h / 7d refinement-quota gauges, per-project status,
and drives resume on macOS. Build and install steps live in
[docs/INSTALL.md](docs/INSTALL.md).

## Honesty box

- **Tier 1** — official `rate_limits` via the statusline — is authoritative but
  requires a recent Claude Code and a Pro/Max login.
- **Tier 2** — the OAuth usage endpoint — is **undocumented and may be
  restricted or removed** at any time. Severance treats every failure as
  expected and degrades silently to Tier 3.
- **Tier 3** — `ccusage` — is a **local estimate**. When it's the only signal
  the gate is deliberately conservative and the state records
  `signal_tier: ccusage` (shown as an *estimate* provenance badge).

Full tier design and caveats: [docs/SIGNALS.md](docs/SIGNALS.md).

## Status

Built milestone by milestone ([`severance-prd.md`](severance-prd.md) §16):

- [x] **M1** — skeleton, JSON-Schema contracts, fixtures, CI (lint + schema)
- [x] **M2** — signal layer (lib, statusline bridge, OAuth fallback, `ccusage`)
- [x] **M3** — gate + resume (preemption, tmux auto-resume, `/severance:severance-status`)
- [x] **M4** — plugin packaging + skills (`claude plugin validate --strict` clean)
- [x] **M5** — macOS menu bar app (`MenuBarExtra`, resume scheduler)
- [x] **M6** — release hardening (release-please, CodeQL, Renovate, compat canary)

First `plugin-v*` / `menubar-v*` releases are cut by merging the release-please PR.

The PRD is the binding spec. [`docs/`](docs/) holds
[architecture](docs/ARCHITECTURE.md), [signals](docs/SIGNALS.md),
[install](docs/INSTALL.md), [upstream doc snapshots](docs/upstream-snapshots/),
and [deviations](docs/DEVIATIONS.md).

## License

[MIT](LICENSE).
