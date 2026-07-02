# Test fixtures

Synthetic fixtures — **no real tokens, no live API data** (PRD §9). Each schema
in `../../schemas/` has a `valid/` and `invalid/` directory here:

| Fixture dir | Validated against |
|---|---|
| `usage-cache/` | `schemas/usage-cache.schema.json` |
| `project-state/` | `schemas/project-state.schema.json` |
| `config/` | `schemas/config.schema.json` |

**Convention (enforced by the `validate-json` CI job):**

- every file under `<schema>/valid/` **must pass** its schema;
- every file under `<schema>/invalid/` **must be rejected** — each isolates one
  contract violation (bad enum, out-of-range threshold, missing required field,
  unexpected property under `additionalProperties: false`).

Changing a schema requires updating the matching fixtures **and** tests in the
same commit (see repo `CLAUDE.md`). Later milestones add hook-stdin and
`ccusage`/OAuth-response fixtures for the bats gate and signal-tier suites.
