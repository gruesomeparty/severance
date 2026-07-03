# Snapshot: release + scanning tooling (M6)

Verified 2026-07-03 via the GitHub API (not the docs, which lagged — the
release-please docs still showed v4).

## release-please

- Action: **`googleapis/release-please-action@v5`** (latest release v5.0.0).
- Manifest mode inputs: `token`, `config-file`, `manifest-file`.
- `release-please-config.json` uses a `packages` map keyed by path; each package:
  `release-type: "simple"`, `component`, `include-component-in-tag: true`,
  `tag-separator: "-"` → tags `plugin-vX.Y.Z` and `menubar-vX.Y.Z`. The plugin
  package bumps `plugin/.claude-plugin/plugin.json` via an `extra-files` json
  updater (`jsonpath: "$.version"`).
- `.release-please-manifest.json` maps path → current version (seeded `0.0.0` so
  the first release PR proposes `0.1.0` from the `feat` history).

## CodeQL

- Action: **`github/codeql-action@v4`** (v2/v3/v4 all exist; v4 is current).
- Swift requires **macOS runners**, build-mode **`manual`** (we add a
  `swift build` step in `apps/menubar`). GitHub Actions workflow scanning uses
  `language: actions`, build-mode **`none`**, on ubuntu.
- Code scanning is free on **public** repos; our `codeql.yml` job is guarded by
  `github.event.repository.visibility == 'public'` so it is a no-op on the
  currently-private repo and activates on the rename to `gruesomeparty` (D4).

## Renovate

- `renovate.json5`, `extends: ["config:recommended", ":semanticCommits"]`.
- Custom regex manager uses `customManagers` (`customType: "regex"`) with
  `managerFilePatterns`, keyed off `# renovate: datasource=… depName=…` comments
  (e.g. the pinned `shfmt` version in `ci.yml`). `ccusage` is intentionally run as
  `npx -y ccusage` (latest), so there is nothing to pin there.
