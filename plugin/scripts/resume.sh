#!/usr/bin/env bash
# resume.sh — return a severed project to the floor (PRD §5.6).
#
#   resume.sh <state-file>   resume one project (re-check first)
#   resume.sh --all          priority-ordered, staggered resume across bands (§5.5)
#
# Interactive-only: if the recorded tmux pane is gone the project is marked
# orphaned and NOT respawned. tmux is invoked via $SEVERANCE_TMUX (default "tmux")
# so tests can point at a scratch server.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugin/scripts/severance-lib.sh disable=SC1091
source "$SCRIPT_DIR/severance-lib.sh"

read -r -a SEV_TMUX <<<"${SEVERANCE_TMUX:-tmux}"

_stagger_secs() {
	if [ -n "${SEVERANCE_RESUME_STAGGER_SECONDS:-}" ]; then
		printf '%s' "$SEVERANCE_RESUME_STAGGER_SECONDS"
		return
	fi
	local mins
	mins="$(jq -r '.resume_stagger_minutes // 15' "$(sev_state_dir)/config.json" 2>/dev/null || echo 15)"
	printf '%s' "$((mins * 60))"
}

_pane_alive() {
	[ -n "$1" ] || return 1
	"${SEV_TMUX[@]}" list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qxF "$1"
}

_iso_epoch() { jq -rn --arg d "$1" '($d | fromdateiso8601) // empty' 2>/dev/null || true; }

# _still_hot <band> — is session utilization still at/above the band's threshold?
_still_hot() {
	local util thr
	util="$(sev_acquire 2>/dev/null | jq -r '.normalized.session.utilization // empty' 2>/dev/null || true)"
	thr="$(sev_ladder "$1" session)"
	[ "$thr" != "null" ] && [ -n "$thr" ] && [ -n "$util" ] || return 1
	awk -v a="$util" -v b="$thr" 'BEGIN{exit !(a + 0 >= b + 0)}'
}

# _resume_one <state-file> — send the continuation prompt (pane alive) or mark
# orphaned. Returns 0 if resumed, 1 if orphaned.
_resume_one() {
	local sf="$1" pane rc
	pane="$(jq -r '.tmux_pane // empty' "$sf" 2>/dev/null || true)"
	rc="$(jq -r '.resume_count // 0' "$sf" 2>/dev/null || echo 0)"
	if _pane_alive "$pane"; then
		local msg="Window has reset. Read .severance/handover.md and continue the task from where it left off."
		# Send the text and Enter as SEPARATE keystrokes with a delay: a TUI like
		# Claude Code treats fast-arriving text like a paste and a same-invocation
		# trailing Enter as a newline, so the message is typed but never submitted.
		# -l sends the text literally; the delayed, separate Enter actually submits.
		"${SEV_TMUX[@]}" send-keys -t "$pane" -l "$msg" 2>/dev/null || true
		sleep "${SEVERANCE_RESUME_ENTER_DELAY:-0.4}"
		"${SEV_TMUX[@]}" send-keys -t "$pane" Enter 2>/dev/null || true
		# shellcheck disable=SC2016
		sev_state_merge "$sf" \
			'. + {status:"active", paused:false, reason:null, preempted_by:null, resume_count:($rc|tonumber), resume_at:null, ts:($ts|tonumber)}' \
			--arg rc "$((rc + 1))" --arg ts "$(sev_now)" || true
		return 0
	fi
	# shellcheck disable=SC2016
	sev_state_merge "$sf" '. + {status:"orphaned", ts:($ts|tonumber)}' --arg ts "$(sev_now)" || true
	return 1
}

_resume_all() {
	local state_dir now stagger band f ra rats first=1
	state_dir="$(sev_state_dir)"
	now="$(sev_now)"
	stagger="$(_stagger_secs)"
	for band in critical high normal low; do
		local due=()
		for f in "$state_dir"/projects/*/*.json; do
			[ -e "$f" ] || continue
			[ "$(jq -r '.status // ""' "$f" 2>/dev/null || true)" = "severed" ] || continue
			[ "$(jq -r '.priority // "normal"' "$f" 2>/dev/null || echo normal)" = "$band" ] || continue
			ra="$(jq -r '.resume_at // empty' "$f" 2>/dev/null || true)"
			if [ -n "$ra" ]; then
				rats="$(_iso_epoch "$ra")"
				if [ -n "$rats" ] && [ "$rats" -gt "$now" ]; then continue; fi
			fi
			due+=("$f")
		done
		[ "${#due[@]}" -gt 0 ] || continue
		[ "$first" -eq 0 ] && sleep "$stagger"
		first=0
		if _still_hot "$band"; then
			for f in "${due[@]}"; do echo "held $(jq -r '.name' "$f")"; done
			continue
		fi
		for f in "${due[@]}"; do
			if _resume_one "$f"; then echo "resumed $(jq -r '.name' "$f")"; else echo "orphaned $(jq -r '.name' "$f")"; fi
		done
	done
}

if [ "${1:-}" = "--all" ]; then
	_resume_all
	exit 0
fi

sf="${1:-}"
[ -n "$sf" ] && [ -f "$sf" ] || exit 0

prio="$(jq -r '.priority // "normal"' "$sf" 2>/dev/null || echo normal)"
if _still_hot "$prio"; then
	# The early-reset assumption was wrong: push resume_at out and bail.
	newr="$(jq -rn --argjson t "$(($(sev_now) + $(_stagger_secs)))" '$t | todate')"
	# shellcheck disable=SC2016
	sev_state_merge "$sf" '. + {resume_at:$r}' --arg r "$newr" || true
	exit 0
fi
_resume_one "$sf" || true
exit 0
