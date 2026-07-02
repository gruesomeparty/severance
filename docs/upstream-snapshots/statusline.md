# Snapshot: statusline (Tier-1 signal)

Source: `https://code.claude.com/docs/en/statusline.md` — captured 2026-07-03.

## How it is wired

`settings.json` → `statusLine.command` points at a shell script. Claude Code
pipes a **single JSON object on stdin** to that command each time it refreshes.
Severance's `statusline-bridge.sh` reads that object, persists the fields it
needs, and delegates to the user's real statusline (`SEVERANCE_INNER_STATUSLINE`).

## Verified stdin object (fields Severance reads)

```json
{
  "session_id": "abc123",
  "model": { "id": "claude-sonnet-5", "display_name": "Sonnet 5" },
  "workspace": { "current_dir": "/path/to/project", "project_dir": "/path/to/project" },
  "cost": {
    "total_cost_usd": 0.01234,
    "total_duration_ms": 45000,
    "total_api_duration_ms": 2300,
    "total_lines_added": 156,
    "total_lines_removed": 23
  },
  "context_window": { "used_percentage": 8, "context_window_size": 200000 },
  "exceeds_200k_tokens": false,
  "rate_limits": {
    "five_hour": { "used_percentage": 23.5, "resets_at": 1738425600 },
    "seven_day": { "used_percentage": 41.2, "resets_at": 1738857600 }
  }
}
```

## `rate_limits` — the authoritative Tier-1 accounting

| Field | Type | Meaning |
|---|---|---|
| `rate_limits.five_hour.used_percentage` | number 0–100 | 5-hour rolling window utilization |
| `rate_limits.seven_day.used_percentage` | number 0–100 | 7-day (weekly) window utilization |
| `rate_limits.five_hour.resets_at` | **Unix epoch seconds** | when the 5h window resets |
| `rate_limits.seven_day.resets_at` | **Unix epoch seconds** | when the 7d window resets |

### Presence / absence rules (must handle defensively)

- `rate_limits` **appears only for Claude.ai subscribers (Pro/Max)** and only
  **after the first API response** in the session.
- Each window (`five_hour`, `seven_day`) may be **independently absent**.
- Docs' own guidance: `jq -r '.rate_limits.five_hour.used_percentage // empty'`.
- `context_window.current_usage`, `used_percentage`, `remaining_percentage` may
  be `null` early in a session / after `/compact`.

## Deltas vs the PRD's assumptions (IMPORTANT — feeds the normalizer)

The PRD (§3, §6.1) speaks of `utilization` and ISO `resets_at`, and of a
`session`/`weekly`/`five_hour` split. Reality as verified:

1. The field is **`used_percentage`**, not `utilization`. → probe both.
2. `resets_at` is **epoch seconds (integer)**, not an ISO string. → the
   normalizer converts to ISO-8601 UTC before writing `usage.json.normalized`.
3. Windows are named **`five_hour`** and **`seven_day`** (same names as the
   Tier-2 OAuth endpoint, but that endpoint uses `utilization` + ISO strings).
4. **No `extra_usage` in statusline.** The used-credits hard-trip signal
   (PRD §5.2 d) is **Tier-2 only**. When only Tier-1 is available, the gate
   cannot see credit burn — documented in `docs/SIGNALS.md`.

### Normalizer probe list (best-first)

```
session.utilization  <- .rate_limits.five_hour.used_percentage   (statusline)
                     |  .five_hour.utilization                    (oauth)
session.resets_at    <- .rate_limits.five_hour.resets_at (epoch)  (statusline)
                     |  .five_hour.resets_at (ISO)                (oauth)
weekly.utilization   <- .rate_limits.seven_day.used_percentage    (statusline)
                     |  .seven_day.utilization                    (oauth)
weekly.resets_at     <- .rate_limits.seven_day.resets_at (epoch)  (statusline)
                     |  .seven_day.resets_at (ISO)                (oauth)
extra_usage          <- (oauth only) .extra_usage
```

Persist the whole `rate_limits` object verbatim in `usage.json` so a future
shape change is recoverable without re-fetching.
