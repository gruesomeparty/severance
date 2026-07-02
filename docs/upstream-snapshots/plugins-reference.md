# Snapshot: plugins reference (manifest + validation)

Source: `https://code.claude.com/docs/en/plugins-reference.md` — captured 2026-07-03.

## `plugin/.claude-plugin/plugin.json`

```json
{
  "name": "severance",
  "version": "1.2.0",
  "description": "…",
  "author": { "name": "gruesomeparty", "email": "…", "url": "…" },
  "homepage": "https://github.com/gruesomeparty/severance",
  "repository": "https://github.com/gruesomeparty/severance",
  "license": "MIT",
  "keywords": ["keyword1", "keyword2"]
}
```

### Field types (verified)

| Field | Required | Type | Notes |
|---|---|---|---|
| `name` | **Yes** (only required field) | string | kebab-case |
| `version` | No | string | semver; users only get updates when this is bumped |
| `description` | No | string | |
| `author` | No | **object** `{name, email?, url?}` | not a bare string |
| `homepage` | No | string URL | |
| `repository` | No | **string URL** | confirms PRD: string, not an object |
| `license` | No | string | |
| `keywords` | No | array<string> | wrong type (string) is a **load error** |
| `dependencies` | No | array<{name, version?}> | semver constraints |

- "If you include a manifest, **`name` is the only required field**."
- Unrecognized fields → **warnings**, not errors.
- Wrong type (e.g. string where array expected) → **load error**.
- `experimental` key now houses `themes` and `monitors` (schema still
  stabilizing; top-level still works but validate warns).

## Validation CLI

```bash
claude plugin validate ./plugin            # validate manifest + component frontmatter + hooks/hooks.json
claude plugin validate ./plugin --strict   # treat warnings as errors — USE IN CI
```
Also available in-session as `/plugin validate`. This is the command referenced
by PRD §9.7 (best-effort smoke) and §8. CI uses `--strict`.

## Component directory conventions

- **Skills:** `skills/<name>/SKILL.md` (a skill is a directory with `SKILL.md`
  plus optional supporting files). Auto-discovered on install.
- **Commands:** `commands/<name>.md` (plain markdown → `/name`).
- **Hooks:** `hooks/hooks.json` (structure in [`hooks.md`](hooks.md)).
- All plugin-internal paths use `${CLAUDE_PLUGIN_ROOT}` (plugins are cached to
  `~/.claude/plugins/` on install, so absolute paths break).

## Severance implications

- `plugin.json`: set `name: severance`, `author` as an object, `repository` as
  the `gruesomeparty/severance` string URL (see DEVIATIONS D4 re: owner).
- Bump `version` on every plugin release (release-please `extra-files` updater,
  M6) or `/plugin update` reports "already at latest".
- CI (M4) runs `claude plugin validate ./plugin --strict` when the CLI is
  installable; otherwise the vendored JSON-schema check covers manifest shape.
