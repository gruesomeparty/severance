# Snapshot: plugin marketplaces (self-marketplace)

Source: `https://code.claude.com/docs/en/plugin-marketplaces.md` — captured 2026-07-03.

## `.claude-plugin/marketplace.json` (repo root)

```json
{
  "name": "severance",
  "owner": { "name": "gruesomeparty", "url": "https://github.com/gruesomeparty" },
  "plugins": [
    {
      "name": "severance",
      "source": "./plugin",
      "description": "Budget-enforcement + auto-resume gate for Claude Code side projects.",
      "version": "1.0.0",
      "author": { "name": "gruesomeparty" }
    }
  ]
}
```

### Field notes (verified)

| Field | Type | Notes |
|---|---|---|
| `name` | string | kebab-case, **public-facing** — users type `…@<name>` on install. One marketplace per name per user. |
| `owner` | **object** `{name, url?}` | not a bare string |
| `metadata.pluginRoot` | string | optional base dir prepended to relative `source` paths |
| `plugins[].name` | string | kebab-case, public-facing |
| `plugins[].source` | string \| object | see below |

### `source` forms

- **Same-repo subdirectory (our case):** a **relative path string** —
  `"source": "./plugin"`. Confirmed against the docs' own examples
  (`"source": "./plugins/formatter"`).
- **External git:** object, e.g.
  `{ "source": "github", "repo": "owner/name" }` or
  `{ "source": "url", "url": "https://…" }` (supports `ref` = branch/tag,
  **not** `sha`).

## Install / add commands (for README + `configuring-severance` skill)

```
/plugin marketplace add gruesomeparty/severance      # add this repo as a marketplace
/plugin install severance@severance                  # install the plugin from it
/plugin marketplace update severance                 # pull catalog changes
```

`<plugin>@<marketplace>` → here both are `severance`, so `severance@severance`
(matches PRD AC7).

## Severance implications / deviations

- `owner.name` = `gruesomeparty`, but the **live repo is `suTerminus/severance`**
  until the username switch — so `/plugin marketplace add gruesomeparty/severance`
  will only resolve after the rename. Verify AC7 against the real remote until
  then. See [`../DEVIATIONS.md`](../DEVIATIONS.md) (D4).
- Both the marketplace `name` and the plugin `name` are `severance`, giving the
  `severance@severance` install target the PRD specifies.
