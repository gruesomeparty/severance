#!/usr/bin/env bash
# statusline-bridge.sh — Severance Tier-1 signal capture (PRD §5.3).
#
# Reads the statusline JSON on stdin, persists the fields Severance needs to
# ~/.claude/severance/usage.json (atomically, under a lock), then delegates the
# SAME stdin to the user's real statusline ($SEVERANCE_INNER_STATUSLINE) so the
# bridge composes with any existing setup. Persistence is best-effort: a failure
# here must never blank the user's status line.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugin/scripts/severance-lib.sh disable=SC1091
source "$SCRIPT_DIR/severance-lib.sh"

# Capture stdin once to a temp file so we can both persist and delegate it byte-for-byte.
tmp_in="$(mktemp)"
trap 'rm -f "$tmp_in"' EXIT
cat >"$tmp_in"

_persist_signal() {
	local state_dir norm usage
	state_dir="$(sev_state_dir)" || return 0
	mkdir -p "$state_dir" 2>/dev/null || return 0
	norm="$(sev_normalize <"$tmp_in")" || return 0
	usage="$(jq \
		--argjson norm "$norm" \
		--argjson ts "$(sev_now)" \
		'{
        ts: $ts,
        signal_tier: "statusline",
        rate_limits: (.rate_limits // null),
        normalized: $norm,
        cost: (.cost // null),
        session_id: (.session_id // null),
        model: (.model | if type == "object" then .id elif type == "string" then . else null end),
        cwd: (.workspace.current_dir // null)
      }' <"$tmp_in")" || return 0
	# Only write if the assembled object is valid JSON.
	printf '%s' "$usage" | jq -e . >/dev/null 2>&1 || return 0
	printf '%s' "$usage" |
		sev_locked "$state_dir/usage.json.lock" sev_atomic_write "$state_dir/usage.json" || return 0
}
_persist_signal || true

# Delegate to the user's real statusline, or print a compact default line.
if [ -n "${SEVERANCE_INNER_STATUSLINE:-}" ]; then
	sh -c "$SEVERANCE_INNER_STATUSLINE" <"$tmp_in"
else
	jq -r '
    (.rate_limits.five_hour.used_percentage // .five_hour.utilization // null) as $u
    | "◦ 5h " + (if $u == null then "—" else (($u | floor | tostring) + "%") end)
  ' <"$tmp_in"
fi
