# Signals

The real plan limit is dynamic, model-weighted, and not exposed by a stable local
API. Severance consumes three tiers, best-first, and records which one produced
each snapshot (`signal_tier`). Verified shapes: [`upstream-snapshots/`](upstream-snapshots/).

## Tier 1 (primary) — official `rate_limits` via the statusline

Recent Claude Code passes a `rate_limits` object in the statusline stdin, parsed
from Anthropic's own response headers — model weighting, limit changes, and usage
from other devices are already included.

- Field shape (verified 2026-07-03): `rate_limits.five_hour.used_percentage`
  (0–100) and `.resets_at` (**Unix epoch seconds**); same for `seven_day`. Note it
  is `used_percentage`, **not** `utilization`, and there is **no `extra_usage`**
  here (Tier-2 only). See DEVIATIONS D3.
- Appears only for Claude.ai subscribers (Pro/Max), after the first API response;
  each window may be independently absent.

Verify:
```bash
cat ~/.claude/severance/usage.json | jq '{tier: .signal_tier, session: .normalized.session, weekly: .normalized.weekly}'
```

## Tier 2 (fallback) — the undocumented OAuth usage endpoint

`GET https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer <token>`
and `anthropic-beta: oauth-2025-04-20`. Response uses `five_hour.utilization`
(0–100) + ISO `resets_at`, and — uniquely — `extra_usage` (`used_credits`), the
direct signal that usage-credit billing is happening.

- **Undocumented and reported flaky/being restricted.** Every non-200/parse
  failure falls through to Tier-3 silently. The token is never logged or persisted.
- Token source: `~/.claude/.credentials.json` → `.claudeAiOauth.accessToken`
  (Linux); macOS Keychain (`security find-generic-password -s 'Claude Code-credentials' -w`).
- Rate-limited to one request per 60s (shared cache).

Verify (only if you have local credentials; makes one authenticated request):
```bash
SEVERANCE_OAUTH_FALLBACK=1 plugin/scripts/oauth-usage.sh | jq '.five_hour, .extra_usage'
```

## Tier 3 (last resort) — local `ccusage` estimate

`npx -y ccusage blocks --json --active` → `.blocks[0].costUSD` / `.totalTokens`.
Local, per-machine, estimate-only. Used only when Tiers 1–2 are unavailable; the
gate is conservative here (trips the cost cap at 60% of the ceiling) and records
`signal_tier: "ccusage"` (shown as an *estimate* provenance badge in the app).

Verify:
```bash
npx -y ccusage blocks --json --active | jq '.blocks[0] | {costUSD, totalTokens}'
```

## Normalizer probe list

`severance-lib.sh` (`sev_normalize`) and the Swift `Normalizer` both probe, per
window (`five_hour` → session, `seven_day` → weekly):

```
utilization  <- .rate_limits.<w>.used_percentage  (statusline)
             |  .rate_limits.<w>.utilization
             |  .<w>.used_percentage
             |  .<w>.utilization              (oauth)
resets_at    <- .rate_limits.<w>.resets_at (epoch → ISO)   (statusline)
             |  .<w>.resets_at (ISO)                        (oauth)
extra_usage  <- .extra_usage                (oauth only)
```

Old shapes are **never removed** from the probe list — older Claude Code versions
stay in the wild. When Anthropic changes a shape, run the `severance-compat-check`
skill: it updates the probe list, fixtures, and schemas together and refreshes the
raw baselines under `upstream-snapshots/raw/` that the weekly `compat.yml` canary
diffs against.

## Which tier am I on?

```bash
/severance:severance-status          # or:
jq -r .signal_tier ~/.claude/severance/usage.json
```
