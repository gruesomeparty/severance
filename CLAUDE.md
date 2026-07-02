# CLAUDE.md — working on the Severance repo

Conventions for agents (and humans) developing **this** repository. The binding
spec is [`severance-prd.md`](severance-prd.md); the M5 visual reference is
[`severance-menubar-mockup.html`](severance-menubar-mockup.html) — **the mockup
wins on visuals, the PRD wins on behavior.** This file governs *how we work*; the
PRD governs *what we build*.

## Golden rules

1. **Conventional commits, real committer, Claude trailer.** Every commit uses
   [Conventional Commits](https://www.conventionalcommits.org/) and ends with:
   ```
   Co-authored-by: Claude <noreply@anthropic.com>
   ```
   Commit as the real author (Berkay). release-please parses these (M6).
2. **Contracts first.** `schemas/*.json` are the API between plugin and app. **A
   schema change must land with its fixture and test updates in the same
   commit.** Never loosen a schema just to make bad data pass.
3. **Tests are synthetic.** No test may hit Anthropic APIs, require a Claude
   login, or contain a real token (PRD §9): Tier 2 → local mock HTTP server,
   Tier 3 → stub `ccusage` on `PATH`, resume → scratch `tmux -L` server.
4. **Never commit secrets.** No credentials, no fixtures with real tokens. The
   OAuth access token is never logged or persisted.
5. **Verify upstream before touching Claude Code surfaces.** The statusline
   schema, hook semantics, and plugin/marketplace manifests drift. Re-fetch
   current docs via the docs map, refresh `docs/upstream-snapshots/`, and record
   any gap in `docs/DEVIATIONS.md` *before* changing dependent code. The
   `severance-compat-check` skill (§11) is the checklist.
6. **Green before next.** A milestone is done only when its tests pass locally
   AND CI is green on its PR. One PR per milestone (PRD §16).

## Local checks (run before pushing)

```bash
bash tests/validate-schemas.sh     # schemas self-check + fixtures (valid pass / invalid rejected)
bash tests/lint-skills.sh          # SKILL.md frontmatter (no-op until M4)
shellcheck --severity=error $(find plugin/scripts tests -name '*.sh')
shfmt -d $(find plugin/scripts tests -name '*.sh')
bats tests/                        # once *.bats exist (M3+)
# macOS app (M5): (cd apps/menubar && swift build && swift test)
```

Tooling: `check-jsonschema`, `shfmt`, `bats-core`, `shellcheck`, `jq`, `tmux`,
Swift 5.10+ — all tracked in the public brew inventory.

## Shell conventions

`#!/usr/bin/env bash`, `set -euo pipefail`, shellcheck-clean at **error**
severity, `shfmt`-clean (tabs). All runtime state writes are atomic
(`mktemp` + `mv`) under `flock`. No network calls on the `PreToolUse` hot path
while the Tier-1 cache is fresh. Plugin scripts reference `${CLAUDE_PLUGIN_ROOT}`
— never absolute paths (plugins are cached to `~/.claude/plugins/`).

## Repo map

| Path | What |
|---|---|
| `plugin/` | the Claude Code plugin (marketplace source `./plugin`) |
| `schemas/` | JSON-Schema contracts for every state file (§6) |
| `tests/` | bats suite, fixtures, and the `validate-schemas` / `lint-skills` helpers |
| `apps/menubar/` | `Severance.app` SwiftPM package (M5) |
| `docs/` | ARCHITECTURE, INSTALL, SIGNALS, DEVIATIONS, `upstream-snapshots/` |
| `.github/workflows/` | CI, CodeQL, release-please, app-release, compat canary |

## The shared state contract (`~/.claude/severance/`)

`usage.json` (signal snapshot — consumers read the `normalized` block),
`config.json` (priority ladder), `projects/<slug>.json` (per-project state). All
JSON, schema-validated in CI, atomic under `flock`. **This directory is the API**
between plugin and app. Signal tiers, best-first: statusline `rate_limits` →
OAuth usage endpoint → `ccusage` estimate; every file records `signal_tier`.

## Repo identity (see docs/DEVIATIONS.md · D4)

Canonical owner in manifests/docs is **`gruesomeparty`**. The live git remote is
**`suTerminus/severance`** until the username switch — push/PR/CI target that
remote; user-facing references say `gruesomeparty`.
