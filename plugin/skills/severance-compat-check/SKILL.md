---
name: severance-compat-check
description: Re-verify Severance against the current Claude Code docs after an upgrade. Use when Claude Code was updated, the weekly compat canary opened an issue, the statusline/hook/plugin schemas may have drifted, or the gate is misbehaving.
---

# Severance compatibility check

Claude Code ships fast. The parts most likely to break Severance: the statusline
stdin schema (`rate_limits` shape), hook event names / exit-code semantics, the
plugin & marketplace manifest fields, and the undocumented Tier-2 endpoint. Turn
"Claude Code updated" into this checklist.

## 1. Fetch the current docs

Start from the docs map and open the hooks, statusline, plugins, and marketplace
pages:

```
https://code.claude.com/docs/en/claude_code_docs_map.md
```

> Note: docs moved from `docs.anthropic.com` to `code.claude.com` (deviation D1).
> The old host 301-redirects, but use the new one.

## 2. Diff against the recorded snapshots

Compare what the docs now say against `docs/upstream-snapshots/` and against what
`plugin/scripts/severance-lib.sh` actually probes:

- **statusline** → `sev_normalize` probe list (`used_percentage` / `utilization`,
  epoch vs ISO `resets_at`, window names `five_hour`/`seven_day`, `extra_usage`).
- **hooks** → event names + exit-code table (esp. whether `SessionStart` can now
  block on exit 2 — deviation D2 — and whether JSON decision output is preferred).
- **plugins / marketplace** → `plugin.json` / `marketplace.json` fields and the
  `claude plugin validate` command.

## 3. If the `rate_limits` shape changed

Update the normalizer **and** fixtures **and** schemas together, in one commit:

- add the new shape to the `sev_normalize` probe list — **never remove an old
  shape** (older Claude Code versions stay in the wild);
- add a `tests/fixtures/signal/` fixture for the new shape;
- adjust `schemas/usage-cache.schema.json` if the normalized block changes;
- refresh `docs/upstream-snapshots/statusline.md`.

## 4. If hook semantics changed

Update `plugin/hooks/hooks.json` and `plugin/scripts/gate.sh` (e.g. if JSON
`permissionDecision` output is now required over exit 2, or an event was renamed).
Re-run `claude plugin validate ./plugin --strict`.

## 5. Probe Tier-2 liveness (only if local credentials exist)

Make at most one authenticated request via `plugin/scripts/oauth-usage.sh`
(never log or persist the token). Record the endpoint's current status in
`docs/SIGNALS.md`. If it's gone, that's expected — the product degrades to Tier-3,
it does not break.

## 6. Verify and open a PR

Run the full suite and manifest validation:

```
bats tests/
bash tests/validate-schemas.sh
bash tests/validate-manifests.sh
claude plugin validate ./plugin --strict
```

Update `docs/DEVIATIONS.md` for anything that diverged, then open a
conventional-commit PR, e.g. `fix(plugin): adapt to Claude Code vX.Y statusline schema`.
