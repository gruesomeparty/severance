#!/usr/bin/env bash
# severance-status.sh — human-readable snapshot of the shared state, printed by
# the /severance:severance-status command. Read-only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugin/scripts/severance-lib.sh disable=SC1091
source "$SCRIPT_DIR/severance-lib.sh"

state_dir="$(sev_state_dir)"
usage="$state_dir/usage.json"

if [ -f "$usage" ]; then
	tier="$(jq -r '.signal_tier // "none"' "$usage" 2>/dev/null || echo none)"
	ts="$(jq -r '.ts // 0' "$usage" 2>/dev/null || echo 0)"
	age=$(($(sev_now) - ts))
	printf 'Severance — signal: %s (updated %ss ago)\n' "$tier" "$age"
	jq -r '
    "  5h refinement quota: " + ((.normalized.session.utilization // "—")|tostring) + "%   resets " + (.normalized.session.resets_at // "—"),
    "  7d refinement quota: " + ((.normalized.weekly.utilization // "—")|tostring) + "%   resets " + (.normalized.weekly.resets_at // "—")
  ' "$usage" 2>/dev/null || true
	credits="$(jq -r '.normalized.extra_usage.used_credits // empty' "$usage" 2>/dev/null || true)"
	[ -n "$credits" ] && printf '  ⚠ usage credits consumed: %s\n' "$credits"
else
	echo "Severance — no usage cache yet (is the statusline bridge configured?)"
fi

echo
echo "Refiners:"
found=0
for f in "$state_dir"/projects/*.json; do
	[ -e "$f" ] || continue
	found=1
	jq -r '
    "  " + .name
    + "  [" + ((.priority // "normal")|ascii_upcase) + "]"
    + "  " + (.status // "?")
    + (if .reason then " (" + .reason + ")" else "" end)
    + (if .session_cost_usd != null then "  $" + (.session_cost_usd|tostring) else "" end)
    + (if .limit_usd != null then " / $" + (.limit_usd|tostring) else "" end)
    + (if .resume_at then "  resumes " + .resume_at else "" end)
    + (if .preempted_by then "  by " + .preempted_by else "" end)
  ' "$f" 2>/dev/null || true
done
[ "$found" -eq 0 ] && echo "  (none tracked)"
exit 0
