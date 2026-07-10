# Deviations from the PRD

Per PRD rule #7 ("When blocked"): where reality contradicts the PRD, Severance
implements the closest spec-compliant alternative, records it here with
evidence, and continues. Each entry links to the verifying snapshot under
[`upstream-snapshots/`](upstream-snapshots/).

---

## D1 — Claude Code docs moved hosts

**PRD says:** docs live at `https://docs.anthropic.com/en/docs/claude-code/…`
(docs map at that host).

**Reality (2026-07-03):** that host **301-redirects** to
`https://code.claude.com/docs/en/…`. Docs map:
`https://code.claude.com/docs/en/claude_code_docs_map.md`.

**Resolution:** all snapshots were captured from `code.claude.com`. The
`compat.yml` canary and `severance-compat-check` skill (M6/§11) use the new
host. The old URL still works via redirect, so links in the PRD are not broken,
only relocated.

**Evidence:** WebFetch of the old docs-map URL returned `301 Moved Permanently`
→ `code.claude.com`.

---

## D2 — `SessionStart` exit 2 cannot block

**PRD says (§5, §5.2):** on `SessionStart`, exit 2 blocks a reopened severed
project with a "still severed until `<resets_at>`" message.

**Reality (2026-07-03):** per the hooks reference, `SessionStart` exit 2 is
**non-blocking** — "Shows stderr to user only." Only `PreToolUse` (among the
events Severance uses) blocks on exit 2.

**Resolution (implemented in M3):** the `SessionStart` gate does **not** try to
block. It (a) refreshes/writes the project heartbeat, and (b) when the project is
still severed, emits `hookSpecificOutput.additionalContext` (JSON, exit 0) noting
it is still severed until `<resets_at>`. Actual enforcement stays on the
`PreToolUse` gate, which blocks the **first tool call** of the reopened session.
Net effect matches PRD intent (no spend while severed); the enforcement point
moves by one hook.

**Evidence:** [`upstream-snapshots/hooks.md`](upstream-snapshots/hooks.md) —
per-event exit-2 table.

---

## D3 — statusline `rate_limits` shape differs from PRD's normalized model

**PRD says (§3, §6.1):** utilization as `utilization` (0–100), `resets_at` as an
ISO string, windows referred to as `session`/`weekly`/`five_hour`.

**Reality (2026-07-03):** Tier-1 statusline emits
`rate_limits.{five_hour,seven_day}.used_percentage` (number 0–100) and
`.resets_at` as **Unix epoch seconds**. There is **no `extra_usage`** in the
statusline payload — it exists only on the Tier-2 OAuth endpoint.

**Resolution:** `severance-lib.sh` normalizer (M2) probes multiple shapes
(`used_percentage` **and** `utilization`), converts epoch → ISO-8601 UTC for the
`normalized` block, and persists the raw `rate_limits` verbatim. The used-credits
hard-trip (§5.2 d) is documented as **Tier-2-only**; when only Tier-1 is live the
gate cannot observe credit burn (noted in `docs/SIGNALS.md`). This is consistent
with the PRD's own instruction to "probe multiple known shapes."

**Evidence:**
[`upstream-snapshots/statusline.md`](upstream-snapshots/statusline.md).

---

## D4 — GitHub owner: `gruesomeparty` (canonical) vs `suTerminus` (live remote)

**PRD says:** owner is `gruesomeparty` (AC7 `/plugin marketplace add
gruesomeparty/severance`; `gruesomeparty/homebrew-tap`).

**Reality:** the live git remote is `git@github.com:suTerminus/severance.git`
(private). The maintainer owns both handles and will rename to `gruesomeparty`
later; renaming now would break references.

**Resolution (confirmed with maintainer):** all human-facing / manifest
references use **`gruesomeparty`** (`marketplace.json` `owner`, `plugin.json`
`author`/`repository`, README install commands, homebrew tap). Git push / PR / CI
operate against **`suTerminus/severance`** until the rename. AC7 is verified
against the real remote until then.

**Evidence:** `git remote -v`; `gh auth status` (active account `suTerminus`);
maintainer confirmation.

---

## D5 — `flock` is not available on macOS

**PRD says (§6):** all state writes are atomic (`mktemp` + `mv`) **under `flock`**.

**Reality:** `flock(1)` ships with util-linux (Linux) but is **not present on
macOS**, and the plugin must run on macOS too (Non-Goals: Linux + macOS only).

**Resolution (M2):** `severance-lib.sh` `sev_locked` uses `flock` when it is on
`PATH` (Linux) and falls back to a portable **`mkdir` mutex** (atomic directory
creation, ~20s timeout) otherwise (macOS). Independently, `sev_atomic_write`
always uses `mktemp` + `mv`, and rename is atomic on POSIX — so whole-file
replaces (e.g. `usage.json`) never interleave even without a lock; the lock only
serializes read-modify-write of shared files. Net behavior matches the PRD's
intent on both platforms. `flock` is auto-used whenever present — it is not a
required install; there is no fallback-vs-flock behavior gap left to document
in the README.

**Evidence:** `command -v flock` → missing on macOS 15.

**Update (#25, crash-safety):** the mkdir mutex had no stale-lock recovery: a
holder that died between `mkdir "$lockdir"` and `rmdir "$lockdir"` (observed
trigger — Claude Code killing the `statusline-bridge.sh` subprocess mid-write
on its statusline timeout) leaked the lock dir forever, freezing the shared
state file for every future caller. The first fix reclaimed any lock dir at
least `SEV_LOCK_STALE_SECS` old — pure age, no liveness check — which traded
the leak for a worse bug below.

**Update (consolidated fix, five defects found in review of the above):**

- **Liveness, not just age (lost updates).** Pure-age reclaim meant a
  still-*alive* holder whose critical section happened to run past
  `SEV_LOCK_STALE_SECS` got its lock dir stolen out from under it — two
  concurrent holders, lost updates on any read-modify-write state (a
  concurrent real-increment test reliably lands short of the writer count
  before this fix and exactly on it after; see `tests/locking.bats`). Fixed
  with a recorded holder pid: right after
  `mkdir` succeeds, the holder publishes `$BASHPID` into `"$lockdir/pid"`
  (via `mktemp` + `mv`, so a concurrent reader never sees a torn write). A
  waiter reclaims only when the recorded pid is dead (`kill -0` fails —
  immediate, regardless of age) or when age reaches `SEV_LOCK_STALE_SECS`
  (default **raised to 300s**) — a large ceiling meant purely as a
  reboot/PID-reuse backstop (`kill -0` can false-positive "alive" against an
  unrelated process that later reuses the same, recycled pid), not something
  normal contention should ever reach. A missing pid file (the ms window
  before a fresh holder publishes it, or a lock dir predating this field) is
  treated the same as live: fresh unless age hits that same ceiling.

- **Trap isolation (D2/D3, the exact #25 trigger reintroduced).** The
  original fix released via `trap ... EXIT INT TERM` set directly in
  `sev_locked`'s own process; `sev_atomic_write` did the same for its
  `mktemp` temp. On the mkdir path both traps live in the *same* process, so
  installing the second silently replaced the first — a signal during
  `sev_atomic_write`'s `cat >"$tmp"` (a real caller composition:
  `sev_locked ... sev_atomic_write ...`) cleaned up the temp but leaked the
  lock dir again. Separately, `sev_locked` unconditionally cleared
  `EXIT INT TERM` on the way out, so a *caller's own* trap (set before
  calling `sev_state_merge`) was silently wiped rather than preserved. Fixed
  by running each release in its own **nested subshell**:
  `sev_locked` runs `"$@"` inside `( trap 'rm -rf "$lockdir"' EXIT;
  trap 'exit 143' TERM; trap 'exit 130' INT; "$@" )`, and `sev_atomic_write`
  wraps its own `mktemp`+`cat`+`mv` in a second, independently-nested
  subshell. A trap set in a nested subshell lives in that subshell's own
  trap table — it can't clobber a trap in the parent process (the caller's)
  or in a sibling nested subshell (`sev_atomic_write`'s vs. `sev_locked`'s).
  There is deliberately **no cleanup after the subshell returns**: an
  earlier draft added a same-process `rm -rf "$lockdir"` there "as a belt,"
  which is actively wrong — a brand-new holder can legitimately re-`mkdir`
  the same lock dir name in the gap between the subshell's own exit and that
  line running, and the belt would then destroy their live lock (reproduced
  empirically under real concurrency). The subshell's own `EXIT` trap is the
  sole release point.

- **TOCTOU on the steal (D4).** The staleness check and the `mv`-aside
  aren't atomic with each other: a lock dir judged reclaimable can be freed
  and legitimately re-acquired by a brand-new holder in the gap between
  them, and the waiter would then steal from that new, live holder instead
  of the stale one it actually meant to reclaim. Mitigated by re-reading the
  stashed dir's pid immediately after the `mv`: if it no longer matches what
  was judged reclaimable a moment ago, this call grabbed someone else's
  fresh lock — best-effort restore it (`mv` back, only if the real
  `"$lockdir"` slot is currently free) and keep waiting, rather than
  destroying it. If the slot's already been retaken by the time the restore
  is attempted too, the stash is dropped instead. This narrows the window to
  a single-host, same-user, sub-millisecond race rather than closing it
  outright — an acceptable, documented residual given the mkdir-mutex is
  itself only a portable fallback for hosts without `flock`.

- **Spin-cap bypass (D5).** The steal branch's `continue` (in the original,
  age-only fix) skipped the `waited`/400-iteration (~20s) accounting
  entirely, so a lock dir that couldn't actually be reclaimed (e.g. a
  permission failure on the `mv`/`rm`) busy-spun forever instead of ever
  hitting the cap. Fixed by always advancing `waited` and re-checking the
  cap on every failed-`mkdir` iteration, whether a reclaim was attempted,
  succeeded, or was skipped.

The flock branch (Linux) is unchanged throughout — it already runs `"$@"` in
its own subshell per invocation and never touches a caller's trap.

**Evidence:** `tests/locking.bats` — 10-writer concurrent RMW (no lost
updates), signal-during-write via the real `sev_locked` + `sev_atomic_write`
composition (no temp, no lock dir), a caller's own trap surviving a direct
`sev_state_merge` call, and an unreclaimable lock dir returning 75 within the
spin cap rather than hanging. All four reproduce the pre-fix defect and pass
after it.

---

## D6 — cost is per-session; utilization is account-global

**PRD implies:** a per-session cost cap (`SEVERANCE_LIMIT_USD`), with cost read from
the single shared `usage.json`.

**Reality (found by running two Claude Code sessions in one repo):** `usage.json`
is keyed by repo, not session, and every session's statusline bridge overwrites it
(last-writer-wins). Reading `cost.total_cost_usd` from it means one session's cap
could be tripped by a **sibling session's** spend. Utilization (`rate_limits`) is
account-global and *correct* to share; **cost is per-session** and was not.

**Resolution:** the statusline bridge additionally writes
`~/.claude/severance/sessions/<session_id>.json` (schema
`schemas/session-cost.schema.json`); `gate.sh` and `heartbeat.sh` read **this**
session's cost from there (falling back to `usage.json` for the single-session
case). Utilization stays shared. The remaining collision — concurrent same-repo
sessions clobbering one `projects/<slug>.json` (status/tmux_pane/resume_at) — is
tracked as a follow-up in GitHub issue #15.

**Also fixed alongside:** `gate.sh` now writes `limit_usd` on the no-trip path, so
`severance-status` no longer shows a stale cap after `SEVERANCE_LIMIT_USD` changes.

**Evidence:** a session whose own cost trajectory was `$2.31 → $2.97` was severed
citing `$46.30` — the value in `usage.json` only while the *other* session was the
last writer.

