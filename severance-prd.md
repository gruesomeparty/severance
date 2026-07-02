# PRD: Severance — Budget Enforcement & Auto-Resume for Claude Code

**Version:** 1.0.0-draft
**Status:** Ready for implementation
**Target:** Public GitHub repository, implemented end-to-end by Claude Code
**License:** MIT

---

## 1. Vision

Severance separates ("severs") side-project Claude Code spending from work spending on a shared Team-plan account. Work sessions run uninterrupted and may roll into organization usage credits. Side projects are hard-gated: before the plan limit (and therefore before usage-credit rollover) is reached, the agent is instructed to write a handover, the session is stopped, and it is automatically resumed in its original tmux pane when the usage window resets.

The system has two deliverables in one monorepo:

1. **`severance` Claude Code plugin** — hooks + statusline bridge + scripts + agent-facing skill. Distributed via a marketplace manifest in this repo so it can be installed standalone or referenced from other marketplaces.
2. **`Severance.app` macOS menu bar app** (Swift, SwiftUI `MenuBarExtra`) — read-only dashboard over the shared state directory, plus the resume scheduler and manual controls on macOS.

Terminology and light theming reference the TV show *Severance*: work spending is the **outie budget** (uninterrupted, allowed to roll into org usage credits), gated side-project spending is the **innie budget** (hard-capped, no memory of what the outie spent — it just knows when the window resets). Gated projects are "severed," resuming is "returning to the severed floor," the utilization gauges are the "refinement quota." Keep it tasteful — labels and an easter egg, not a UI gimmick.

## 2. Goals & Non-Goals

### Goals
- G1: Never allow a gated project to trigger usage-credit (API-rate) billing on a Team plan.
- G2: Gate on **official** utilization data (Anthropic's own accounting), not local token estimates, so the gate keeps working when Anthropic changes limits or model weightings.
- G3: Zero-friction resume: agent writes its own handover; system re-injects a continuation prompt into the original tmux pane at window reset.
- G4: Per-project opt-in and per-project budgets. Work repos are unaffected by installing the plugin org-wide.
- G5: Fully observable: all state is plain JSON files under one directory; the menu bar app (or `cat`) is just a reader.
- G6: Maintainable against Claude Code's fast release cadence via bundled maintenance skills and CI schema checks.

### Non-Goals
- No headless (`claude -p` / Agent SDK) orchestration. Interactive terminal sessions under tmux only.
- No server component, no telemetry, no network calls except the documented fallback endpoint.
- No Windows support. Linux (gate + systemd resume) and macOS (gate + menu bar app resume) only.
- No attempt to read or scrape `claude.ai` web usage pages.

## 3. Background: Signal Sources (implementation-critical)

The core design problem: the real plan limit is dynamic, model-weighted, and not exposed via a stable local API. Severance therefore consumes signals in three tiers, best-first:

### Tier 1 (primary): official `rate_limits` via statusline stdin
Recent Claude Code versions pass a `rate_limits` object in the JSON piped to the configured statusline command on stdin, parsed internally from API response headers (`anthropic-ratelimit-unified-5h-utilization`, `anthropic-ratelimit-unified-7d-utilization`). This is Anthropic's authoritative accounting: model weighting, limit changes, and usage from other devices/surfaces are already included.

- Severance ships a statusline wrapper that (a) extracts `rate_limits` (and `cost`, `session_id`, `workspace.current_dir`, `model`) to a cache file and (b) delegates to the user's existing statusline command unchanged, so it composes with any setup.
- **The exact field names inside `rate_limits` must be verified at implementation time against the current Claude Code statusline docs** (see §11 maintenance skill). Write the extractor defensively: persist the whole `rate_limits` object verbatim, and have consumers probe multiple known shapes (e.g. `five_hour`/`session`, `utilization` as 0–100 number).

### Tier 2 (fallback): undocumented OAuth usage endpoint
`GET https://api.anthropic.com/api/oauth/usage` with headers `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`, `Content-Type: application/json`. Known response shape:

```json
{
  "five_hour":  { "utilization": 37.0, "resets_at": "2026-02-08T04:59:59+00:00" },
  "seven_day":  { "utilization": 26.0, "resets_at": "2026-02-12T14:59:59+00:00" },
  "seven_day_sonnet": { "utilization": 1.0, "resets_at": "..." },
  "extra_usage": { "is_enabled": false, "monthly_limit": null, "used_credits": null, "utilization": null }
}
```

Token source: `~/.claude/.credentials.json` → `.claudeAiOauth.accessToken` on Linux; macOS Keychain generic password service `Claude Code-credentials` (`security find-generic-password -s 'Claude Code-credentials' -w`).

- This endpoint is **undocumented and reported flaky/being restricted** (some accounts get "OAuth authentication is currently not supported"). Treat every failure mode as expected: on any non-200 or parse failure, fall through to Tier 3 silently and record `signal_tier` in state.
- `extra_usage` is uniquely valuable: it directly indicates whether usage credits are enabled/burning. If `extra_usage.used_credits > 0` during a gated project's session, trip the gate immediately regardless of thresholds (this is the exact event Severance exists to prevent).
- Never log or persist the token. Rate-limit calls: min 60s between requests, shared cache under `flock`.

### Tier 3 (last resort): local cost estimate via `ccusage`
`npx -y ccusage blocks --json --active` → `.blocks[0].costUSD` / `.totalTokens`. Local, per-machine, estimate-only. Used only when Tiers 1–2 are unavailable (fresh machine, endpoint dead). Gate conservatively here (default trip at 60% of the configured cost ceiling) and mark state `confidence: "estimate"`.

Every state file records which tier produced the numbers (`signal_tier: "statusline" | "oauth" | "ccusage"`).

## 4. Repository Layout (monorepo)

```
severance/
├── .claude-plugin/
│   └── marketplace.json            # self-marketplace: lists the plugin below
├── plugin/                         # the Claude Code plugin (marketplace source: ./plugin)
│   ├── .claude-plugin/
│   │   └── plugin.json             # name, version, description, author, repository, license
│   ├── hooks/
│   │   └── hooks.json              # PreToolUse, SessionStart, Stop registrations
│   ├── scripts/
│   │   ├── severance-lib.sh        # shared: config resolution, signal tiers, state I/O, locking
│   │   ├── gate.sh                 # PreToolUse + SessionStart gate
│   │   ├── heartbeat.sh            # Stop hook: refresh project state after each turn
│   │   ├── statusline-bridge.sh    # statusline wrapper: cache rate_limits, delegate
│   │   ├── resume.sh               # tmux send-keys resume (used by systemd unit & app)
│   │   ├── schedule-resume.sh      # Linux: systemd-run --user one-shot at resets_at
│   │   └── oauth-usage.sh          # Tier-2 fetch with caching + flock
│   ├── skills/
│   │   ├── configuring-severance/
│   │   │   └── SKILL.md            # consumer-facing: how to enable/tune in a repo (§10)
│   │   └── severance-compat-check/
│   │       └── SKILL.md            # maintenance: verify against current CC docs (§11)
│   └── commands/
│       └── severance-status.md     # /severance:severance-status — print current state
├── apps/
│   └── menubar/                    # Swift Package: Severance.app (§7)
│       ├── Package.swift
│       ├── Sources/Severance/...
│       └── Tests/SeveranceTests/...
├── schemas/                        # JSON Schema for every state file (§6)
│   ├── usage-cache.schema.json
│   ├── project-state.schema.json
│   └── config.schema.json
├── tests/                          # bats + fixtures (§9)
│   ├── fixtures/
│   └── *.bats
├── docs/
│   ├── ARCHITECTURE.md
│   ├── INSTALL.md                  # plugin install, statusline setup, app install
│   └── SIGNALS.md                  # tier details, endpoint caveats, verification steps
├── .github/
│   ├── workflows/                  # ci.yml, codeql.yml, release-please.yml, app-release.yml
│   └── renovate.json5
├── release-please-config.json
├── .release-please-manifest.json
├── CLAUDE.md                       # repo conventions for agents working ON this repo
├── README.md
└── LICENSE
```

Plugin structure follows the official convention: manifest at `plugin/.claude-plugin/plugin.json`, hooks at `plugin/hooks/hooks.json`, skills under `plugin/skills/<name>/SKILL.md`. All hook commands reference scripts via `${CLAUDE_PLUGIN_ROOT}/scripts/...` — never absolute paths (plugins are cached to `~/.claude/plugins/` on install).

Verify the current manifest/marketplace field requirements against the plugins reference at implementation time (`repository` is a string URL, not an object; marketplace `plugins[].source` uses `"./plugin"` relative source).

## 5. Component 1: The Plugin

### 5.1 Hook registrations (`plugin/hooks/hooks.json`)

| Event | Matcher | Handler | Purpose |
|---|---|---|---|
| `PreToolUse` | `*` | `gate.sh` | Gate every tool call inside the agentic loop (covers long automode runs). |
| `SessionStart` | — | `gate.sh --session-start` | Fail fast when a severed project is reopened before reset; also write initial heartbeat. |
| `Stop` | — | `heartbeat.sh` | Refresh project state (cost so far, status) once per turn for the dashboard. |

Set explicit `timeout` values (10s gate, 5s heartbeat). Hooks block the loop; everything must be fast — no network calls on the hot path when the Tier-1 cache is fresh.

### 5.2 Gate algorithm (`gate.sh`)

```
1. Resolve config (§5.4). If not enabled for this project → exit 0 immediately.
   (Enablement is explicit: SEVERANCE_ENABLED=1 in project settings env. Installing
   the plugin alone must be a no-op — G4.)
2. If manual pause flag set in project state (paused=true, set by app/user or by
   preemption, §5.5) → trip (step 7).
3. Resolve effective thresholds: priority ladder entry for SEVERANCE_PRIORITY
   (§5.4), overridden by explicit SEVERANCE_UTIL_PCT / SEVERANCE_WEEKLY_PCT if set.
   Priority "critical" → utilization gates off (ladder entry null).
4. Acquire signal (tiers, §3). Extract: session utilization %, session resets_at,
   weekly utilization %, extra_usage if available.
5. Read project-local session cost (statusline cache `cost.total_cost_usd` for this
   session_id; Tier-3 fallback: ccusage per-project JSONL sum).
6. Evaluate trip conditions (OR):
     a. session_utilization >= effective session threshold   (skip if critical)
     b. weekly_utilization  >= effective weekly threshold    (skip if critical)
     c. project_session_cost >= SEVERANCE_LIMIT_USD          (if set; applies to ALL
        priorities incl. critical — cost caps are absolute)
     d. extra_usage.used_credits > 0   (all priorities; only disabled by explicit
        SEVERANCE_ALLOW_EXTRA_USAGE=1, intended for critical/work projects only)
     e. paused == true
7. On trip:
     a. Write project state (§6.2): reason, numbers, signal_tier, resets_at,
        priority, tmux pane ($TMUX_PANE), session_id, cwd, resume_count.
     b. If resume_count < SEVERANCE_MAX_RESUMES (default 3): schedule resume —
        Linux: schedule-resume.sh (systemd-run --user --on-calendar=<resets_at>
        --unit=severance-resume-<project> --collect); macOS: no-op (menu bar app
        owns scheduling by watching state files).
     c. Emit stderr instruction and exit 2:
        "SEVERANCE [<reason>]: session window at <X>% (limit <Y>% for priority
         <prio>). Write a concise handover of current task state, next steps, and
         open questions to .severance/handover.md now, then stop. Do not call
         further tools after writing the handover. Resume is scheduled for <resets_at>."
8. Preemption sweep (§5.5): if this project's priority reserves headroom and
   utilization exceeds the reserve threshold of any lower priority, write
   paused=true + reason="preempted" into every enabled lower-priority project's
   state file. (Runs on the non-tripped path too — an active high-prio session
   continuously defends its headroom.)
9. Exit 0.
```

Exit code 2 on `PreToolUse` blocks the tool call and feeds stderr back to the model — the message doubles as the handover instruction. On `SessionStart`, exit 2 blocks with the same message minus the handover request ("still severed until <resets_at>").

Edge case: the handover write itself is a tool call (`Write` to `.severance/handover.md`). The gate must allow it: whitelist tool calls whose target path is inside `.severance/` even while tripped (parse `tool_input.file_path` from the hook's stdin JSON). Without this, the agent can never comply with the instruction.

### 5.3 Statusline bridge (`statusline-bridge.sh`)

```
INPUT=$(cat)
# 1. Persist signal (atomic write + flock):
echo "$INPUT" | jq '{rate_limits, cost, session_id, model: .model.id,
                     cwd: .workspace.current_dir, ts: now}' \
  >> atomic-replace ~/.claude/severance/usage.json
# 2. Delegate to the user's real statusline:
echo "$INPUT" | exec "$SEVERANCE_INNER_STATUSLINE"   # configured; default: passthrough minimal line
```

`INSTALL.md` documents the one manual step: setting `statusLine.command` in `~/.claude/settings.json` to the bridge, with `SEVERANCE_INNER_STATUSLINE` pointing at any pre-existing script. The `configuring-severance` skill automates this for agents.

If the current Claude Code version doesn't emit `rate_limits` (older version, or field renamed), the bridge still writes `cost`/`session_id`, and consumers fall to Tier 2.

### 5.4 Configuration

Resolution order: project `.claude/settings.json` `env` block → user `~/.claude/severance/config.json` → defaults. All variables:

| Variable | Default | Meaning |
|---|---|---|
| `SEVERANCE_ENABLED` | `0` | Master switch, per project. Must be `1` to gate. |
| `SEVERANCE_PRIORITY` | `normal` | `critical` \| `high` \| `normal` \| `low`. Selects ladder entry. |
| `SEVERANCE_UTIL_PCT` | unset | Explicit override of the ladder's session threshold. |
| `SEVERANCE_WEEKLY_PCT` | unset | Explicit override of the ladder's weekly threshold. |
| `SEVERANCE_LIMIT_USD` | unset | Optional per-project session cost cap (absolute, all priorities). |
| `SEVERANCE_ALLOW_EXTRA_USAGE` | `0` | Disable the used-credits hard trip. Intended for critical/work only. |
| `SEVERANCE_MAX_RESUMES` | `3` | Auto-resume attempts per severance before requiring manual resume. |
| `SEVERANCE_STATE_DIR` | `~/.claude/severance` | Shared state root. |
| `SEVERANCE_INNER_STATUSLINE` | unset | Delegated statusline command. |
| `SEVERANCE_OAUTH_FALLBACK` | `1` | Allow Tier-2 endpoint calls. |

**Priority ladder** — lives once in user-level `config.json` (schema-validated; these are the defaults). Projects declare *how much they matter*; the ladder decides *when they trip* — analogous to under-frequency load shedding: as utilization climbs, feeders drop in reverse priority order.

```json
{
  "ladder": {
    "critical": { "session": null, "weekly": null, "reserve": null },
    "high":     { "session": 85,   "weekly": 95,   "reserve": 60 },
    "normal":   { "session": 70,   "weekly": 85,   "reserve": null },
    "low":      { "session": 50,   "weekly": 70,   "reserve": null }
  },
  "resume_stagger_minutes": 15
}
```

`session`/`weekly`: trip thresholds for that priority (`null` = utilization gate off). `reserve`: preemption threshold — see §5.6.

### 5.5 Preemption & priority-ordered resume

**Preemption (headroom reservation).** When a project whose ladder entry has a non-null `reserve` runs its gate (PreToolUse or SessionStart) and session utilization ≥ `reserve`, the gate writes `paused: true, reason: "preempted", preempted_by: <slug>` into the state file of every *enabled, lower-priority* project (discovered via `projects/*.json`, `status != severed`). Those projects' own gates observe the flag at their next tool call, so a preempted agent writes its handover and yields within one turn. Effect: starting (or continuing) high-priority work actively evicts side projects to defend headroom — a critical feeder coming online trips shedding downstream. Preemption never touches equal or higher priorities, and never touches projects whose gate is disabled.

**Priority-ordered resume.** At window reset, resume schedulers (systemd units on Linux fire independently, so ordering is enforced by `resume.sh` itself; the macOS app orders natively) process severed projects **highest priority first** with `resume_stagger_minutes` between priority bands: resume all `high`, wait, re-check utilization against the next band's threshold, then resume `normal`, and so on. A `reason: "preempted"` project resumes only if the preemptor's `reserve` is no longer exceeded. This prevents the freshly reset window from being instantly consumed by the least important work.

### 5.6 Resume (`resume.sh`)

Input: path to a project state file. Behavior:

```
1. Refresh signal; if still >= threshold (early reset assumption wrong) → reschedule +15min, exit.
2. If tmux pane from state still exists (tmux list-panes -a -F '#{pane_id}'):
     tmux send-keys -t <pane> "Window has reset. Read .severance/handover.md and continue the task from where it left off." Enter
3. Else: mark state status="orphaned" (pane gone). Do NOT spawn new sessions —
   interactive-only per Non-Goals; the menu bar app / user resumes manually.
4. Increment resume_count, set status="active", clear resumeAt.
```

## 6. Shared State Contract (`~/.claude/severance/`)

All files are JSON, schema-validated in CI, written atomically (`mktemp` + `mv`) under `flock`. This directory **is** the API between plugin and app.

### 6.1 `usage.json` (written by statusline bridge / oauth fetch)
```json
{
  "ts": 1751450000,
  "signal_tier": "statusline",
  "rate_limits": { "...verbatim object from Claude Code..." },
  "normalized": {
    "session": { "utilization": 62.0, "resets_at": "2026-07-02T18:00:00Z" },
    "weekly":  { "utilization": 41.0, "resets_at": "2026-07-07T09:00:00Z" },
    "extra_usage": { "is_enabled": false, "used_credits": null }
  },
  "cost": { "total_cost_usd": 1.42 },
  "session_id": "…", "model": "…", "cwd": "…"
}
```
The `normalized` block is produced by `severance-lib.sh` from whichever tier fired; consumers only read `normalized`.

### 6.2 `projects/<slug>.json` (written by gate/heartbeat/resume/app)
```json
{
  "name": "one-ocean-cms",
  "cwd": "/home/berkay/dev/one-ocean-cms",
  "status": "active | severed | orphaned | paused",
  "reason": "session_util | weekly_util | cost_limit | extra_usage | manual | preempted",
  "priority": "critical | high | normal | low",
  "preempted_by": null,
  "session_cost_usd": 2.31,
  "limit_usd": 3.0,
  "utilization_at_trip": 81.0,
  "signal_tier": "statusline",
  "tmux_pane": "%12",
  "session_id": "…",
  "severed_at": "2026-07-02T15:04:00Z",
  "resume_at": "2026-07-02T18:00:00Z",
  "resume_count": 1,
  "paused": false
}
```
Slug = basename of cwd, sanitized. Heartbeat updates `session_cost_usd`/`status` each turn.

## 7. Component 2: macOS Menu Bar App

**Stack:** Swift 5.10+, SwiftUI, `MenuBarExtra` (`.menuBarExtraStyle(.window)`), macOS 14+. Swift Package (executable target) — no Xcode project file; build with `swift build`, bundle into `.app` via a small `scripts/bundle-app.sh` (create `Severance.app/Contents/{MacOS,Resources}`, Info.plist with `LSUIElement=true`).

### Features
1. **Menu bar label:** compact utilization, e.g. `◦ 5h 62%`; turns orange ≥ threshold−10, red ≥ threshold. Data from `usage.json`.
2. **Panel:** two `Gauge` views (5h / 7d) with reset countdowns; provenance badge when `signal_tier != "statusline"` ("estimate"); project list from `projects/*.json` sorted by priority — each row: name, priority chip (`CRIT`/`HIGH`/`NORM`/`LOW`), status chip (`ACTIVE` / `SEVERED` / `PAUSED` / `ORPHANED`, plus `PREEMPTED by <name>` when applicable), cost vs limit bar, resume countdown.
3. **Per-project actions:** *Sever now* / *Resume now* (writes `paused` flag / invokes `resume.sh` via `Process` + `tmux`), *Open handover* (opens `.severance/handover.md`).
4. **Resume scheduler (macOS replacement for systemd):** the store observes state files; for any `status=severed` with future `resume_at`, hold a `Timer`; on fire, run `resume.sh <state>` in priority order with the configured stagger between bands (§5.5). Persist across app restarts by re-deriving timers from state files at launch (stateless scheduling — the files are the source of truth).
5. **File watching:** `DispatchSource.makeFileSystemObjectSource` on the state dir + 30s timer fallback.
6. **Tier-2 fallback fetch** when `usage.json` is stale >5 min and user enabled it: token via Keychain (`security find-generic-password -s 'Claude Code-credentials' -w`), same caching rules as the shell implementation. Never store the token.
7. **Easter egg:** when the 7d window resets, show a one-shot "🧇 Waffle party — weekly quota refreshed" notification (UserNotifications, optional in settings).

Design: Lumon-adjacent restraint — monochrome + one blue accent, SF Symbols, no chrome. Sandbox off (needs tmux + Keychain + arbitrary file reads); document this in INSTALL.md.

## 8. CI/CD (GitHub Actions)

### 8.1 `ci.yml` — every PR + main
- **lint-shell:** `shellcheck` (error severity) + `shfmt -d` on `plugin/scripts/**`.
- **validate-json:** `check-jsonschema` — validate `plugin.json`, `marketplace.json`, `hooks.json` (against a vendored minimal schema), all `schemas/*.json` self-check, all `tests/fixtures/*.json` against their schemas.
- **test-plugin (ubuntu):** bats suite (§9). Installs `bats-core`, `jq`, `tmux`.
- **test-app (macos-14):** `swift build -c release && swift test`, then `scripts/bundle-app.sh`, `ditto -c -k Severance.app Severance-macos.zip`, upload as workflow artifact.
- **skill-lint:** validate SKILL.md frontmatter (name/description present, description length, body <500 lines).

### 8.2 `codeql.yml`
CodeQL default setup as workflow: languages `swift` (macos runner) and `actions`. Scheduled weekly + PR.

### 8.3 `release-please.yml`
Release-please in **manifest mode**, two components:
- `plugin` (release-type `simple`, path `plugin/`) — bumps `plugin/.claude-plugin/plugin.json` `version` via `extra-files` JSON updater, tags `plugin-vX.Y.Z`.
- `menubar` (release-type `simple`, path `apps/menubar/`) — tags `menubar-vX.Y.Z`.

Conventional commits enforced by a commitlint PR check. Root `CHANGELOG.md` per component directory.

### 8.4 `app-release.yml`
On `menubar-v*` tag: macos-14 runner → build, bundle (including ad-hoc `codesign -s -` so arm64 runs), zip → attach to the GitHub release. Include an optional, secret-gated codesign+notarize step (`if: secrets.MACOS_CERT_P12 != ''`) with `codesign`/`notarytool`; unsigned zip is the default artifact with Gatekeeper bypass instructions in INSTALL.md. Follow-up (v1.x, scaffold the job now behind `if: false`): push a cask version/sha256 bump to the `gruesomeparty/homebrew-tap` repo on each release, so distribution becomes `brew install --cask gruesomeparty/tap/severance`.

### 8.5 `renovate.json5`
Renovate app (not a workflow): `config:recommended`, managers: `github-actions`, `swift` (Package.swift deps if any), custom regex manager pinning the `ccusage` version referenced in scripts, `npm` if a package.json exists for tooling. Weekly schedule, semantic commits, automerge for patch-level actions digests.

### 8.6 Scheduled compat canary — `compat.yml`
Weekly cron: fetch the Claude Code docs pages for hooks and statusline (docs map at `https://docs.anthropic.com/en/docs/claude-code/claude_code_docs_map.md`), diff stored copies under `docs/upstream-snapshots/`, and open an issue titled "Upstream Claude Code docs changed — run /severance:severance-compat-check" when the hooks/statusline pages change. This is the automated tripwire; the skill (§11) is the remediation path.

## 9. Testing Strategy (synthetic)

No test may hit Anthropic APIs or require a Claude login. Everything is driven by fixtures and fakes.

1. **Gate unit tests (bats):** feed synthetic hook stdin JSON (PreToolUse payloads with `tool_name`, `tool_input.file_path`) + fixture `usage.json` variants; assert exit codes, stderr content, and resulting state files. Cases: below threshold, at threshold, weekly trip, cost trip, `extra_usage.used_credits>0` trip, handover-path whitelist while tripped, disabled project no-op, paused trip, max-resumes exhausted, stale cache fallthrough, malformed cache. Ladder cases: same utilization fixture trips `low` but not `high`; `critical` never utilization-trips but still cost-trips; explicit `SEVERANCE_UTIL_PCT` overrides ladder; `SEVERANCE_ALLOW_EXTRA_USAGE=1` disables (only) trip d. Preemption cases: high-prio gate at util ≥ reserve pauses enabled lower-prio projects only (not equal/higher, not disabled, not already-severed); paused project trips with `reason=preempted`; preempted project does not auto-resume while preemptor's reserve is still exceeded.
2. **Signal tier tests:** Tier-2 mocked with a local Python `http.server` fixture serving canned responses (200 good, 200 malformed, 401 "OAuth not supported", timeout) on `127.0.0.1`; fake credentials file; assert tier selection and `signal_tier` recording. Tier-3 mocked by a stub `ccusage` on PATH emitting fixture JSON.
3. **Resume tests (bats + tmux):** start a scratch `tmux -L severance-test` server in CI, create a pane, write a state file pointing at it, run `resume.sh`, assert via `tmux capture-pane` that the continuation prompt arrived; orphaned-pane case asserts `status=orphaned` and no spawn.
4. **Statusline bridge tests:** pipe fixture statusline JSON (with and without `rate_limits`) through the bridge; assert cache contents, atomicity (concurrent invocations under `flock` don't interleave), and that the inner statusline receives identical stdin.
5. **Schema tests:** every fixture and every file produced by the above validated against `schemas/`.
6. **Swift tests:** `SeveranceStore` parsing of fixture state dirs (happy, partial, corrupt), timer derivation from `resume_at`, normalized-shape probing. UI untested beyond store logic.
7. **End-to-end smoke (best effort, non-blocking job):** if `claude` CLI is installable in CI, run `claude plugin validate ./plugin` (or the current equivalent validation command per docs) to catch manifest drift.

## 10. Consumer-Facing Skill: `configuring-severance`

Ships **inside the plugin** so any agent in a consuming repo knows how to set Severance up. SKILL.md description (pushy, per skill-writing best practice): *"Configure the Severance budget gate for this repository. Use whenever the user mentions severance, budget gates, usage limits for side projects, stopping Claude Code before extra spending, or auto-resume after limit resets — even if they don't name the plugin."*

Body instructs the agent to:
1. Confirm the plugin is installed (`claude plugin list` / settings `enabledPlugins`); if not, add the marketplace and install (`/plugin marketplace add <owner>/severance`, `/plugin install severance@severance`).
2. Write the project `env` block (`SEVERANCE_ENABLED=1`, `SEVERANCE_PRIORITY=<asked or inferred: work repos → critical, everything else → ask>`, plus any explicit overrides) into `.claude/settings.json`, explaining the ladder defaults.
3. Set up the statusline bridge in user settings if absent, preserving any existing statusline via `SEVERANCE_INNER_STATUSLINE`.
4. Add `.severance/` to `.gitignore` (handover + state are local).
5. Run `/severance:severance-status` to verify signal acquisition and report which tier is live.

## 11. Maintenance Skill: `severance-compat-check`

The moving parts most likely to break: statusline stdin schema (`rate_limits` shape), hook event names/exit-code semantics, plugin manifest fields, the Tier-2 endpoint. This skill turns "Claude Code updated" into a checklist an agent can execute:

1. Fetch current docs via the docs map (`https://docs.anthropic.com/en/docs/claude-code/claude_code_docs_map.md` → hooks reference, statusline, plugins reference pages).
2. Diff documented schemas against `docs/upstream-snapshots/` and against what `severance-lib.sh` probes for.
3. If `rate_limits` shape changed: update the normalizer + fixtures + schemas together; add the old shape to the probe list (never remove — old CC versions stay in the wild).
4. If hook semantics changed (e.g. JSON decision output preferred over exit codes): update `hooks.json` + gate accordingly.
5. Probe Tier-2 liveness (a single authenticated request if credentials exist locally, otherwise skip) and update `docs/SIGNALS.md` status notes.
6. Run the full test suite; bump fixtures; open a conventional-commit PR (`fix(plugin): adapt to Claude Code vX.Y statusline schema`).

Triggered manually, by the weekly `compat.yml` issue, or whenever an agent notices gate misbehavior.

## 12. Documentation Requirements

- **README.md:** what/why in three paragraphs, framed in innie/outie terms (your outie works unbudgeted on the org's dime; your innie gets a hard allowance and a scheduled return to the severed floor), a terminal screencap placeholder, quickstart (marketplace add → install → enable in one repo → statusline bridge), menu bar app install, threat-model honesty box ("Tier 2 is undocumented and may die; Tier 1 requires a recent Claude Code; estimates are estimates").
- **docs/ARCHITECTURE.md:** the diagram below + state machine (`active → severed → active / orphaned`, `paused` orthogonal).
- **docs/SIGNALS.md:** everything in §3 with verification commands.
- **docs/INSTALL.md:** per-OS, including unsigned-app Gatekeeper steps and tmux assumptions.
- **CLAUDE.md (repo root):** conventions for agents developing this repo — conventional commits with real committer + `Co-authored-by` trailer, run bats before pushing, never commit credentials/fixtures containing real tokens, schema changes require fixture + test updates in the same commit.

```
statusline (official rate_limits)          oauth endpoint (fallback)      ccusage (estimate)
        │                                          │                            │
        └──────────────► severance-lib normalizer ◄┴────────────────────────────┘
                                   │
                          ~/.claude/severance/usage.json
                                   │
        ┌──────────────────────────┼───────────────────────────┐
   gate.sh (PreToolUse/            │                     Severance.app
   SessionStart, exit 2)     projects/*.json ◄──────────  (reader + macOS
        │                          ▲                       resume scheduler)
   handover.md ◄─ agent            │                            │
        │                    heartbeat.sh (Stop)          tmux send-keys
   schedule-resume.sh (Linux, systemd-run) ────────► resume.sh ─┘
```

## 13. Acceptance Criteria

- AC1: With `SEVERANCE_ENABLED=1` and a fixture cache at 85% utilization, any tool call is blocked with exit 2 and the handover instruction; writes to `.severance/` still pass.
- AC2: With the plugin installed but `SEVERANCE_ENABLED` unset, all hooks are provable no-ops (<50ms, exit 0).
- AC3: A severed state file with `resume_at` in the past and a live tmux test pane results in the continuation prompt appearing in that pane (Linux via systemd path in manual test; CI via direct `resume.sh`).
- AC4: Killing Tier 1 and Tier 2 (no cache, endpoint returning 401) still yields a functioning conservative gate via Tier 3, with `signal_tier: "ccusage"` recorded.
- AC5: `extra_usage.used_credits: 12.5` in the cache trips the gate regardless of thresholds and priority, unless `SEVERANCE_ALLOW_EXTRA_USAGE=1`.
- AC6: Fresh clone → `swift build && swift test` and `bats tests/` pass on the pinned toolchains; CI green includes CodeQL, schema validation, and artifact upload.
- AC7: `/plugin marketplace add <repo>` followed by `/plugin install severance@severance` succeeds against a pushed copy of the repo.
- AC8: release-please produces independent `plugin-v*` and `menubar-v*` releases from conventional commits, with the app zip attached to menubar releases.
- AC9: Menu bar app reflects a state-file change within 2 seconds while open, and derives correct resume timers after a relaunch.
- AC10: With the default ladder and a fixture at 72% session utilization, a `low` and a `normal` project trip while a `high` project passes; the same fixture with `SEVERANCE_UTIL_PCT=75` on the `low` project lets it pass.
- AC11: A `high`-priority gate run at utilization ≥ its `reserve` (60) writes `paused=true, reason=preempted` into an enabled `normal` project's state; that project's next PreToolUse trips within one tool call; a `critical` project's state is untouched.
- AC12: With one `high` and one `low` project severed past `resume_at`, the resume path resumes `high` first and delays `low` by `resume_stagger_minutes`, re-checking utilization in between (assert via mocked signal + captured tmux prompts).

## 14. Follow-ups (explicitly out of v1 scope)

- **F1 — Burn-rate / pace-aware shedding (v2):** point-in-time thresholds can be beaten by a fast burner (40% utilization with 4h of window left still lets a heavy low-prio agent eat everything). v2 compares `utilization / elapsed_window_fraction` per band and sheds lower priorities that burn faster than the clock. Requires window start time (derivable from `resets_at` − 5h) and a smoothing choice; design doc first, behind a config flag, default off.
- **F2 — Homebrew tap automation:** enable the scaffolded `gruesomeparty/homebrew-tap` cask-bump job (§8.4).
- **F3 — Linux desktop notifications:** `notify-send` on sever/resume in `resume.sh`.

## 15. Risks & Open Questions

- **R1 — Tier-2 endpoint removal:** expected eventually. Mitigated by tier design + compat canary; the product degrades, never breaks.
- **R2 — `rate_limits` schema drift:** mitigated by verbatim persistence + probing normalizer + weekly docs diff.
- **R3 — Blocked-tool loop:** a model that ignores the stop instruction burns turns against blocked calls. Mitigate: after N=5 consecutive blocked calls in one session (counter in project state), escalate the stderr message and stop scheduling resumes for the session.
- **R4 — Unattended resume spends unattended:** bounded by `SEVERANCE_MAX_RESUMES` and re-check-on-resume; worst case ≈ (threshold headroom) × max_resumes.
- **R5 — Preemption write races:** multiple concurrent gates writing lower-prio state files. Mitigated by per-file `flock` + read-modify-write of only the pause fields; last-writer-wins is acceptable for a boolean pause. Preemption sweeps are throttled (once per 60s per preemptor, timestamp in own state file) so hot tool loops don't hammer the state dir.

## 16. Implementation Order (suggested milestones)

1. **M1 — Skeleton + contracts:** repo layout, schemas, fixtures, CI (lint + schema jobs), CLAUDE.md.
2. **M2 — Signal layer:** `severance-lib.sh`, statusline bridge, oauth fallback, ccusage stub, tier tests.
3. **M3 — Gate + resume:** gate.sh, heartbeat.sh, resume.sh, schedule-resume.sh, full bats suite, `/severance:severance-status` command.
4. **M4 — Plugin packaging:** plugin.json, hooks.json, marketplace.json, both skills, `claude plugin validate`, INSTALL/README.
5. **M5 — Menu bar app:** store + panel + scheduler + bundle script + Swift tests + app-release workflow.
6. **M6 — Release hardening:** release-please, CodeQL, Renovate, compat canary, docs polish, first tagged releases.

Each milestone must land with green CI before the next begins. Commits: conventional, real committer, `Co-authored-by: Claude <noreply@anthropic.com>` trailer.
