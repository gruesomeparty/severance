# Snapshot: ccusage (Tier-3 estimate)

Source: `npx -y ccusage@latest blocks --json --active` — verified 2026-07-03.

Tier-3 is a **local, per-machine cost estimate** (no API, no login). Severance uses
it only when Tiers 1–2 are unavailable, and gates conservatively (PRD §3).

## Verified output shape

`.blocks` is an array of usage "blocks" (rolling 5-hour windows). The active block
is `.blocks[0]` when `--active` is passed. Its relevant keys:

```
.blocks[0].costUSD        number   estimated USD spend in the active block  (used by Severance)
.blocks[0].totalTokens    number   total tokens in the active block
.blocks[0].isActive       bool
.blocks[0].startTime      string   ISO-8601
.blocks[0].endTime        string   ISO-8601
.blocks[0].burnRate       object
.blocks[0].projection     object
.blocks[0].tokenCounts    object   {inputTokens, outputTokens, cacheCreationInputTokens, cacheReadInputTokens}
.blocks[0].models         array
```

This matches the PRD's `.blocks[0].costUSD` / `.totalTokens` — **no deviation**.

## Severance usage

- `severance-lib.sh` → `sev_ccusage` runs `ccusage blocks --json --active` (or
  `npx -y ccusage` when no `ccusage` is on PATH; overridable via
  `SEVERANCE_CCUSAGE_CMD` for tests, which stub it rather than hitting npm).
- `sev_acquire` maps `costUSD` → `normalized`-less `cost.total_cost_usd`, sets
  `signal_tier: "ccusage"` and leaves utilization `null` (no official accounting
  at this tier); the gate then applies conservative cost logic.
