#!/usr/bin/env bash
# severance-lib.sh — shared library for the Severance plugin scripts.
#
# This file is meant to be *sourced* (gate.sh, heartbeat.sh, statusline-bridge.sh,
# resume.sh, oauth-usage.sh). It defines functions only and deliberately does NOT
# set global `set -euo pipefail` — that is the caller's job — so sourcing it never
# changes the caller's shell options unexpectedly.
#
# Conventions: all runtime writes are atomic (mktemp + mv); read-modify-write of a
# shared file is guarded by sev_locked. `flock` is used when present (Linux); macOS
# has no flock, so a portable mkdir mutex is the fallback (see docs/DEVIATIONS.md D5).

# Directory holding this library and its sibling scripts, resolved at source time.
SEV_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SEV_SELF_DIR="."

# ---- paths & identity -------------------------------------------------------

# sev_state_dir — the shared state root (SEVERANCE_STATE_DIR or ~/.claude/severance).
sev_state_dir() {
	printf '%s\n' "${SEVERANCE_STATE_DIR:-$HOME/.claude/severance}"
}

# sev_slug <path> — filesystem-safe project slug: basename with unsafe characters
# replaced by '-', repeats collapsed, and leading/trailing '-' trimmed.
sev_slug() {
	local base
	base="$(basename -- "$1")"
	base="$(printf '%s' "$base" | tr -c 'A-Za-z0-9._-' '-')"
	base="$(printf '%s' "$base" | sed -E 's/-+/-/g; s/^-+//; s/-+$//')"
	printf '%s\n' "$base"
}

# ---- configuration ----------------------------------------------------------

# sev_config_get <VAR> [default] — resolve a SEVERANCE_* value.
# Order (PRD §5.4): environment (project settings `env` is exported into hooks) >
# user config.json `.defaults[VAR]` > built-in default argument.
sev_config_get() {
	local var="$1" default="${2-}" cfg val
	if [ -n "${!var-}" ]; then
		printf '%s\n' "${!var}"
		return 0
	fi
	cfg="$(sev_state_dir)/config.json"
	if [ -f "$cfg" ]; then
		val="$(jq -r --arg k "$var" '.defaults[$k] // empty' "$cfg" 2>/dev/null || true)"
		if [ -n "$val" ]; then
			printf '%s\n' "$val"
			return 0
		fi
	fi
	printf '%s\n' "$default"
}

# ---- signal normalization ---------------------------------------------------

# sev_now — current time in Unix epoch seconds.
sev_now() { date +%s; }

# sev_normalize — read a raw tier signal on stdin, emit the normalized block
# {session, weekly, extra_usage}. Probes multiple known shapes (D3): statusline
# uses .rate_limits.<w>.used_percentage + epoch resets_at; the OAuth endpoint uses
# .<w>.utilization + ISO resets_at. Epoch resets_at are converted to ISO-8601 UTC.
# extra_usage exists only on the OAuth endpoint; it is null otherwise.
sev_normalize() {
	jq '
      def util($w):
        (.rate_limits[$w].used_percentage // .rate_limits[$w].utilization
         // .[$w].used_percentage // .[$w].utilization // null);
      def reset($w):
        ((.rate_limits[$w].resets_at // .[$w].resets_at // null)
         | if type == "number" then todate
           elif type == "string" then .
           else null end);
      {
        session: { utilization: util("five_hour"), resets_at: reset("five_hour") },
        weekly:  { utilization: util("seven_day"), resets_at: reset("seven_day") },
        extra_usage: {
          is_enabled:   .extra_usage.is_enabled,
          used_credits: .extra_usage.used_credits
        }
      }'
}

# ---- atomic I/O & locking ---------------------------------------------------

# sev_atomic_write <dest> — write stdin to <dest> atomically (mktemp in the same
# directory + mv, so readers never see a partial file). mktemp+cat+mv run in a
# nested subshell with their own EXIT/INT/TERM trap so a death before the mv
# (e.g. the writer killed mid-write, #25) leaves no `.sev.*` behind. Being a
# NESTED subshell, this trap can never clobber sev_locked's own release trap
# (see sev_locked) or a caller's trap in the un-subshelled parent process —
# each trap table lives in its own process, and mv is the atomic commit point,
# so the trap's `rm -f` is a harmless no-op once it lands.
sev_atomic_write() {
	local dest="$1" dir tmp
	dir="$(dirname -- "$dest")"
	mkdir -p "$dir"
	tmp="$(mktemp "$dir/.sev.XXXXXX")"
	(
		trap 'rm -f "$tmp"' EXIT INT TERM
		cat >"$tmp"
		mv -f "$tmp" "$dest"
	)
}

# _sev_file_age_secs <path> — seconds since <path>'s mtime (BSD `stat -f` vs GNU
# `stat -c`). Used by sev_locked's mkdir-fallback to detect a stale lock dir.
_sev_file_age_secs() {
	local f="$1" mtime now
	now="$(sev_now 2>/dev/null || date +%s)"
	mtime="$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null)" || return 1
	printf '%s\n' "$((now - mtime))"
}

# _sev_lock_reclaimable <lockdir> <stale_secs> — on success (exit 0), prints
# the pid a waiter judged reclaimable (empty if none was recorded) and may
# steal <lockdir>. Liveness-primary (D1): a recorded holder pid ($lockdir/pid,
# published by sev_locked right after mkdir) that's dead is reclaimed
# immediately, regardless of age. A holder proven alive (`kill -0`) is
# reclaimed only once age >= <stale_secs> — a large ceiling, meant purely as a
# reboot/PID-reuse backstop (kill -0 can false-positive "alive" against an
# unrelated process that happens to now hold the same, recycled pid after a
# reboot). A missing pid file — the ms window before a fresh holder publishes
# it, or a lock dir predating this field — is treated the same as a live
# holder: fresh unless age >= that same ceiling.
_sev_lock_reclaimable() {
	local lockdir="$1" stale="$2" age pid
	pid=""
	{ IFS= read -r pid <"$lockdir/pid"; } 2>/dev/null
	if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
		age="$(_sev_file_age_secs "$lockdir" 2>/dev/null)" || return 1
		[ "$age" -ge "$stale" ] || return 1
		printf '%s\n' "$pid"
		return 0
	fi
	if [ -n "$pid" ]; then
		printf '%s\n' "$pid" # dead: reclaim now, regardless of age
		return 0
	fi
	age="$(_sev_file_age_secs "$lockdir" 2>/dev/null)" || return 1
	[ "$age" -ge "$stale" ] || return 1
	printf '\n' # no pid on record, but old enough to be the ceiling case
	return 0
}

# sev_locked <lockfile> <cmd...> — run <cmd...> holding an exclusive lock.
# Uses flock when available; otherwise a portable mkdir mutex (macOS has no
# flock; set SEV_LOCK_NO_FLOCK=1 to force the mkdir fallback on any host, for
# testing). Returns the command's exit status (75/EX_TEMPFAIL if the lock can't
# be acquired).
#
# The mkdir fallback recovers a stale lock dir (#25: a dead holder — e.g.
# killed mid-write — used to leak it forever, wedging every future sev_locked
# caller) via _sev_lock_reclaimable's liveness-primary rule (D1, see its
# header) rather than pure age: a holder this call can independently prove
# alive is never stolen from, no matter how long its critical section runs.
#
# The steal is still a mv-then-rm so two racers can't both reclaim (#25's
# original protection), but the staleness check and the mv aren't atomic with
# each other: the lock dir a waiter judged reclaimable can be freed and
# legitimately re-acquired by a brand-new holder in the gap between them (D4).
# After the mv, the stashed dir's pid is re-read; if it no longer matches what
# was judged reclaimable a moment ago, this call grabbed someone else's fresh
# lock instead of the stale one — best-effort restore it (mv back, only if the
# real "$lockdir" slot is free) and keep waiting rather than destroy it. If
# the slot's already been retaken by then too, the stash is dropped; this is a
# documented, single-host/same-user, sub-millisecond residual window (see
# docs/DEVIATIONS.md D5). A lock that can't be reclaimed at all (e.g. a
# permission failure on the mv/rm) still advances the ~20s spin-cap accounting
# below on every failed-mkdir iteration, reclaim attempted or not, so it
# returns 75 rather than busy-spinning forever (D5).
#
# Release is trap-based, scoped to a nested subshell running the critical
# section: "$@" executes inside `( trap ... EXIT INT TERM; "$@" )`, so its
# trap lives in that subshell's own trap table and can't clobber a trap
# sev_atomic_write sets in ITS OWN nested subshell (D2/D3 — previously both
# traps lived in the same process and the second install silently replaced
# the first, leaking the lock dir if a signal landed during the write) nor a
# trap the caller had already set before calling sev_locked (D2 — previously
# an unconditional `trap - EXIT INT TERM` cleared it). Nothing runs after the
# subshell returns beyond reporting its status: an unconditional second
# cleanup there would race a brand-new holder who's already re-acquired the
# same lock dir name by then (proven empirically) — the subshell's own EXIT
# trap is the sole release point.
sev_locked() {
	local lockfile="$1"
	shift
	if [ -z "${SEV_LOCK_NO_FLOCK:-}" ] && command -v flock >/dev/null 2>&1; then
		(
			flock -x 9 || exit 75
			"$@"
		) 9>"$lockfile"
		return $?
	fi
	local lockdir="$lockfile.d" waited=0 rc=0 stale expected_pid stash now_pid
	stale="${SEV_LOCK_STALE_SECS:-300}"
	while ! mkdir "$lockdir" 2>/dev/null; do
		if expected_pid="$(_sev_lock_reclaimable "$lockdir" "$stale" 2>/dev/null)"; then
			stash="$lockdir.stale.${BASHPID:-$$}.$waited"
			if mv "$lockdir" "$stash" 2>/dev/null; then
				now_pid=""
				{ IFS= read -r now_pid <"$stash/pid"; } 2>/dev/null
				if [ "$now_pid" = "$expected_pid" ]; then
					rm -rf "$stash" 2>/dev/null
				else
					{ [ ! -e "$lockdir" ] && mv "$stash" "$lockdir" 2>/dev/null; } || rm -rf "$stash" 2>/dev/null
				fi
			fi
		fi
		sleep 0.05
		waited=$((waited + 1))
		if [ "$waited" -ge 400 ]; then # ~20s
			return 75
		fi
	done

	# Publish our pid via mktemp+mv (not a direct write) so a concurrent
	# reader in _sev_lock_reclaimable never sees a torn/partial write.
	printf '%s' "${BASHPID:-$$}" >"$lockdir/.pid.${BASHPID:-$$}" 2>/dev/null &&
		mv -f "$lockdir/.pid.${BASHPID:-$$}" "$lockdir/pid" 2>/dev/null || true

	if (
		trap 'rm -rf "$lockdir" 2>/dev/null || true' EXIT
		trap 'exit 143' TERM
		trap 'exit 130' INT
		"$@"
	); then
		rc=0
	else
		rc=$?
	fi
	return "$rc"
}

# ---- ladder & project state -------------------------------------------------

# sev_ladder <priority> <session|weekly|reserve> — print the threshold for a
# priority band. Reads config.json .ladder first (an explicit null there means
# "gate off"), else the built-in defaults (PRD §5.4). Prints the literal "null"
# when the gate is disabled.
sev_ladder() {
	local prio="$1" field="$2" cfg val
	cfg="$(sev_state_dir)/config.json"
	if [ -f "$cfg" ]; then
		val="$(jq -r --arg p "$prio" --arg f "$field" '
        if ((.ladder[$p] // {}) | has($f))
        then (.ladder[$p][$f] | if . == null then "null" else tostring end)
        else "MISSING" end' "$cfg" 2>/dev/null || echo MISSING)"
		if [ "$val" != "MISSING" ]; then
			printf '%s\n' "$val"
			return 0
		fi
	fi
	case "$prio:$field" in
	high:session) echo 85 ;;
	high:weekly) echo 95 ;;
	high:reserve) echo 60 ;;
	normal:session) echo 70 ;;
	normal:weekly) echo 85 ;;
	low:session) echo 50 ;;
	low:weekly) echo 70 ;;
	*) echo null ;; # critical:* and *:reserve default to off
	esac
}

# sev_project_state_file <slug> <session_id> — path to a session's project-state
# JSON, partitioned per session (issue #15): projects/<slug>/<session_id>.json.
# The session id is sanitized to a filesystem-safe token exactly as
# sev_session_cost_file does, so concurrent same-repo sessions never clobber one
# another's status/resume_at/tmux_pane/blocked_count.
sev_project_state_file() {
	local sid
	sid="$(printf '%s' "$2" | tr -c 'A-Za-z0-9._-' '-')"
	printf '%s\n' "$(sev_state_dir)/projects/$1/$sid.json"
}

# sev_session_cost_file <session_id> — path to a session's per-session cost record
# (sanitized filename). Cost is per-session, so the cost cap reads THIS session's
# file rather than the shared usage.json, which is clobbered by concurrent
# same-repo sessions (last-writer-wins). See docs/DEVIATIONS.md D6.
sev_session_cost_file() {
	local sid
	sid="$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-')"
	printf '%s\n' "$(sev_state_dir)/sessions/$sid.json"
}

# _sev_merge_rmw <statefile> <jq_filter> [jq_args...] — read-modify-write body,
# always run under sev_state_merge's lock. Resets an unparseable file to {}.
_sev_merge_rmw() {
	local sf="$1" filter="$2" existing
	shift 2
	existing="$(cat "$sf" 2>/dev/null || true)"
	printf '%s' "$existing" | jq -e . >/dev/null 2>&1 || existing="{}"
	printf '%s' "$existing" | jq "$@" "$filter" | sev_atomic_write "$sf"
}

# sev_state_merge <statefile> <jq_filter> [jq_args...] — atomically merge a jq
# transform into a project state file, serialized by a per-file lock so
# concurrent gates/heartbeats/preemption sweeps never lose updates.
sev_state_merge() {
	local sf="$1"
	mkdir -p "$(dirname "$sf")"
	sev_locked "$sf.lock" _sev_merge_rmw "$@"
}

# _sev_prio_rank <priority> — numeric rank for comparison (higher = more important).
_sev_prio_rank() {
	case "$1" in
	critical) echo 3 ;;
	high) echo 2 ;;
	normal) echo 1 ;;
	low) echo 0 ;;
	*) echo 1 ;;
	esac
}

# sev_preempt_sweep <slug> <session_id> <priority> <session_util> — headroom
# preemption (§5.5). When this project's band reserves headroom (non-null reserve)
# and session utilization is at/above it, pause every ENABLED, strictly-LOWER-
# priority session RECORD (a state file implies it was enabled) that is not already
# severed/orphaned. Preemption is per-session (issue #15): each lower-priority
# session file is paused individually; the preemptor's own sessions (same slug) are
# skipped. Throttled to once per 60s per preemptor session via preempt_sweep_ts (R5).
sev_preempt_sweep() {
	local slug="$1" sid="$2" prio="$3" util="$4"
	local reserve
	reserve="$(sev_ladder "$prio" reserve)"
	[ "$reserve" != "null" ] && [ -n "$reserve" ] || return 0
	[ -n "$util" ] || return 0
	awk -v a="$util" -v b="$reserve" 'BEGIN{exit !(a + 0 >= b + 0)}' || return 0

	local state_dir sf now last myrank
	state_dir="$(sev_state_dir)"
	sf="$(sev_project_state_file "$slug" "$sid")"
	now="$(sev_now)"

	last="$(jq -r '.preempt_sweep_ts // 0' "$sf" 2>/dev/null || echo 0)"
	if [ "$last" != "0" ] && [ "$last" != "null" ] && [ $((now - last)) -lt 60 ]; then
		return 0
	fi
	# shellcheck disable=SC2016
	sev_state_merge "$sf" '. + {preempt_sweep_ts:($t|tonumber)}' --arg t "$now" || true

	myrank="$(_sev_prio_rank "$prio")"
	local f other_slug other_prio other_status
	for f in "$state_dir"/projects/*/*.json; do
		[ -e "$f" ] || continue
		other_slug="$(basename "$(dirname "$f")")"
		[ "$other_slug" = "$slug" ] && continue
		other_prio="$(jq -r '.priority // "normal"' "$f" 2>/dev/null || echo normal)"
		other_status="$(jq -r '.status // "active"' "$f" 2>/dev/null || echo active)"
		case "$other_status" in severed | orphaned) continue ;; esac
		[ "$(_sev_prio_rank "$other_prio")" -lt "$myrank" ] || continue
		# shellcheck disable=SC2016
		sev_state_merge "$f" \
			'. + {paused:true, reason:"preempted", preempted_by:$by, status:"paused", ts:($t|tonumber)}' \
			--arg by "$slug" --arg t "$now" || true
	done
	return 0
}

# ---- tier acquisition -------------------------------------------------------

# sev_ccusage — emit ccusage's active-block JSON, or fail. Honors
# SEVERANCE_CCUSAGE_CMD (a full command; used by tests to stub Tier-3); otherwise
# runs the real `ccusage` (or `npx -y ccusage` when none is installed).
sev_ccusage() {
	if [ -n "${SEVERANCE_CCUSAGE_CMD:-}" ]; then
		sh -c "$SEVERANCE_CCUSAGE_CMD" 2>/dev/null
		return
	fi
	if command -v ccusage >/dev/null 2>&1; then
		ccusage blocks --json --active 2>/dev/null
	else
		npx -y ccusage blocks --json --active 2>/dev/null
	fi
}

# sev_acquire [max_age_secs] — pick the best available signal and print
# {signal_tier, normalized, cost} on stdout. Order (PRD §3): fresh statusline
# cache (Tier 1) > OAuth (Tier 2, if SEVERANCE_OAUTH_FALLBACK) > ccusage estimate
# (Tier 3) > stale statusline cache (last resort). Refreshes usage.json for
# tiers 2-3. Returns non-zero only when no signal at all is available.
sev_acquire() {
	local max_age state_dir usage ts now age raw norm cost usage_obj
	max_age="${1:-${SEVERANCE_TIER1_MAX_AGE:-120}}"
	state_dir="$(sev_state_dir)"
	mkdir -p "$state_dir"
	usage="$state_dir/usage.json"

	# Tier 1: fresh statusline cache with usable session utilization.
	if [ -f "$usage" ]; then
		ts="$(jq -r '.ts // 0' "$usage" 2>/dev/null || echo 0)"
		now="$(sev_now)"
		age=$((now - ts))
		if [ "$age" -ge 0 ] && [ "$age" -lt "$max_age" ] &&
			[ "$(jq -r '.signal_tier // ""' "$usage" 2>/dev/null)" = "statusline" ] &&
			[ "$(jq -r '.normalized.session.utilization' "$usage" 2>/dev/null)" != "null" ]; then
			jq -c '{signal_tier, normalized, cost}' "$usage"
			return 0
		fi
	fi

	# Tier 2: OAuth endpoint (if enabled).
	if [ "$(sev_config_get SEVERANCE_OAUTH_FALLBACK 1)" = "1" ]; then
		if raw="$("$SEV_SELF_DIR/oauth-usage.sh" 2>/dev/null)"; then
			norm="$(printf '%s' "$raw" | sev_normalize)"
			usage_obj="$(jq -n --argjson norm "$norm" --argjson ts "$(sev_now)" \
				'{ts: $ts, signal_tier: "oauth", rate_limits: null, normalized: $norm, cost: null, session_id: null, model: null, cwd: null}')"
			printf '%s' "$usage_obj" | sev_locked "$state_dir/usage.json.lock" sev_atomic_write "$usage"
			printf '%s' "$usage_obj" | jq -c '{signal_tier, normalized, cost}'
			return 0
		fi
	fi

	# Tier 3: ccusage estimate (no official utilization; cost only).
	if raw="$(sev_ccusage)" && cost="$(printf '%s' "$raw" | jq -e -r '.blocks[0].costUSD' 2>/dev/null)"; then
		norm="$(printf '%s' '{}' | sev_normalize)"
		usage_obj="$(jq -n --argjson norm "$norm" --argjson ts "$(sev_now)" --argjson cost "$cost" \
			'{ts: $ts, signal_tier: "ccusage", rate_limits: null, normalized: $norm, cost: {total_cost_usd: $cost}, session_id: null, model: null, cwd: null}')"
		printf '%s' "$usage_obj" | sev_locked "$state_dir/usage.json.lock" sev_atomic_write "$usage"
		printf '%s' "$usage_obj" | jq -c '{signal_tier, normalized, cost}'
		return 0
	fi

	# Last resort: a stale statusline cache beats no signal at all.
	if [ -f "$usage" ] && [ "$(jq -r '.signal_tier // ""' "$usage" 2>/dev/null)" = "statusline" ]; then
		jq -c '{signal_tier, normalized, cost}' "$usage"
		return 0
	fi

	return 1
}
