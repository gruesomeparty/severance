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
intent on both platforms.

**Evidence:** `command -v flock` → missing on macOS 15.

