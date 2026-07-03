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
# directory + mv, so readers never see a partial file).
sev_atomic_write() {
	local dest="$1" dir tmp
	dir="$(dirname -- "$dest")"
	mkdir -p "$dir"
	tmp="$(mktemp "$dir/.sev.XXXXXX")"
	cat >"$tmp"
	mv -f "$tmp" "$dest"
}

# sev_locked <lockfile> <cmd...> — run <cmd...> holding an exclusive lock.
# Uses flock when available; otherwise a portable mkdir mutex (macOS has no flock).
# Returns the command's exit status (75/EX_TEMPFAIL if the lock can't be acquired).
sev_locked() {
	local lockfile="$1"
	shift
	if command -v flock >/dev/null 2>&1; then
		(
			flock -x 9 || exit 75
			"$@"
		) 9>"$lockfile"
		return $?
	fi
	local lockdir="$lockfile.d" waited=0 rc=0
	while ! mkdir "$lockdir" 2>/dev/null; do
		sleep 0.05
		waited=$((waited + 1))
		if [ "$waited" -ge 400 ]; then # ~20s
			return 75
		fi
	done
	"$@" || rc=$?
	rmdir "$lockdir" 2>/dev/null || true
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

# sev_project_state_file <slug> — path to a project's state JSON.
sev_project_state_file() {
	printf '%s\n' "$(sev_state_dir)/projects/$1.json"
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

# sev_preempt_sweep <slug> <priority> <session_util> — headroom preemption (§5.5).
# When this project's band reserves headroom (non-null reserve) and session
# utilization is at/above it, pause every ENABLED, strictly-LOWER-priority project
# (a state file implies it was enabled) that is not already severed/orphaned.
# Throttled to once per 60s per preemptor via preempt_sweep_ts (R5).
sev_preempt_sweep() {
	local slug="$1" prio="$2" util="$3"
	local reserve
	reserve="$(sev_ladder "$prio" reserve)"
	[ "$reserve" != "null" ] && [ -n "$reserve" ] || return 0
	[ -n "$util" ] || return 0
	awk -v a="$util" -v b="$reserve" 'BEGIN{exit !(a + 0 >= b + 0)}' || return 0

	local state_dir sf now last myrank
	state_dir="$(sev_state_dir)"
	sf="$(sev_project_state_file "$slug")"
	now="$(sev_now)"

	last="$(jq -r '.preempt_sweep_ts // 0' "$sf" 2>/dev/null || echo 0)"
	if [ "$last" != "0" ] && [ "$last" != "null" ] && [ $((now - last)) -lt 60 ]; then
		return 0
	fi
	# shellcheck disable=SC2016
	sev_state_merge "$sf" '. + {preempt_sweep_ts:($t|tonumber)}' --arg t "$now" || true

	myrank="$(_sev_prio_rank "$prio")"
	local f other_slug other_prio other_status
	for f in "$state_dir"/projects/*.json; do
		[ -e "$f" ] || continue
		other_slug="$(basename "$f" .json)"
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
