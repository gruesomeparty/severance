# Upstream snapshots

Verified captures of the Claude Code surfaces Severance depends on, taken at
**implementation time** (PRD rule #1) so the maintenance skill
(`severance-compat-check`, PRD §11) and the weekly `compat.yml` canary have a
baseline to diff against.

- **Captured:** 2026-07-03
- **Source host:** `https://code.claude.com/docs/en/`
- **Docs map:** `https://code.claude.com/docs/en/claude_code_docs_map.md`
  (`Last updated: 2026-07-02 22:20:16 UTC`)

> **Docs moved hosts.** The PRD references
> `https://docs.anthropic.com/en/docs/claude-code/...`. That host now
> **301-redirects** to `https://code.claude.com/docs/en/...`. The compat canary
> (`compat.yml`) and the `severance-compat-check` skill must use the new host.
> See [`../DEVIATIONS.md`](../DEVIATIONS.md) (D1).

## Files

| Snapshot | Upstream page | Severance dependency |
|---|---|---|
| [`statusline.md`](statusline.md) | `statusline.md` | Tier-1 signal: `rate_limits` shape, `cost`, `session_id`, `model`, `workspace.current_dir` |
| [`hooks.md`](hooks.md) | `hooks.md` | gate/heartbeat: event names, PreToolUse/SessionStart/Stop stdin, exit-code semantics |
| [`plugins-reference.md`](plugins-reference.md) | `plugins-reference.md` | `plugin.json` manifest fields, `claude plugin validate --strict` |
| [`plugin-marketplaces.md`](plugin-marketplaces.md) | `plugin-marketplaces.md` | `marketplace.json`, `plugins[].source`, add/install commands |

| [`ccusage.md`](ccusage.md) | `ccusage blocks --json` | Tier-3 estimate: `costUSD`/`totalTokens` |
| [`release-tooling.md`](release-tooling.md) | GitHub API | M6: release-please v5, codeql-action v4, Renovate |

## Raw baselines (`raw/`)

`raw/{hooks,statusline,plugins-reference,plugin-marketplaces}.md` are verbatim
copies of the upstream pages. The weekly `compat.yml` canary re-fetches each page
and diffs it against these; on any change it opens an issue pointing at the
`severance-compat-check` skill (which updates the shapes **and** refreshes these
baselines in the same PR).

## How to refresh

The `severance-compat-check` skill (PRD §11) re-fetches each page via the docs
map, diffs it against these files, and — when a shape changes — updates the
normalizer probe list, fixtures, and schemas together in one PR. Never delete an
old shape from a probe list: older Claude Code versions stay in the wild.
