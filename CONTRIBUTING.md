# Contributing

Thanks for helping sever spend from spend. Bug reports, cask/packaging fixes, and
signal-tier robustness improvements are especially welcome.

## Prerequisites

macOS or Linux, plus (all in the public Homebrew inventory):
`check-jsonschema`, `shfmt`, `bats-core`, `shellcheck`, `jq`, `tmux`, and Swift 5.10+
for the menu bar app.

```sh
brew install check-jsonschema shfmt bats-core shellcheck jq tmux
```

## Local checks (run before pushing)

```sh
bash tests/validate-schemas.sh        # JSON-Schema contracts + fixtures
bash tests/validate-manifests.sh      # plugin.json / marketplace.json vs vendored schemas
bash tests/lint-skills.sh             # SKILL.md frontmatter
shellcheck --severity=error $(find plugin/scripts tests apps/menubar/scripts -name '*.sh')
shfmt -d $(find plugin/scripts tests apps/menubar/scripts -name '*.sh')
bats tests/                           # synthetic — no API, no login, no real tokens
claude plugin validate ./plugin --strict
(cd apps/menubar && swift build && swift test)
```

CI runs the same checks; `main` is protected, so open a PR and let it go green.

## Conventions

- **Conventional Commits**, committed as the real author with a
  `Co-authored-by: Claude <noreply@anthropic.com>` trailer. `release-please` parses
  these to cut `plugin-v*` / `menubar-v*` releases.
- **Contracts first.** `schemas/*.json` are the API between the plugin and the app; a
  schema change lands with its fixtures **and** tests in the same commit.
- **Tests are synthetic.** Never hit Anthropic APIs, require a login, or commit a real
  token (Tier-2 → local mock HTTP server, Tier-3 → stub `ccusage`, resume → scratch
  `tmux` server).
- **Verify upstream before touching Claude Code surfaces.** The statusline schema, hook
  semantics, and plugin manifests drift — re-fetch the current docs, refresh
  `docs/upstream-snapshots/`, and record any gap in `docs/DEVIATIONS.md`. The
  `severance-compat-check` skill is the checklist.
- **Linear history.** PRs merge by squash or rebase.

Full working conventions for agents and humans: [CLAUDE.md](CLAUDE.md). The binding
spec is [severance-prd.md](severance-prd.md); deviations from it are logged in
[docs/DEVIATIONS.md](docs/DEVIATIONS.md).
