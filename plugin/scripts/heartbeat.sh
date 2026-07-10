#!/usr/bin/env bash
# heartbeat.sh — Severance Stop hook (PRD §5.1).
#
# Refreshes the project's dashboard state once per turn: session cost so far,
# signal tier, and a timestamp. It never changes a severed/paused status (that
# is the gate's / resume's job) — it only keeps the numbers current. No-op unless
# the project is enabled.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugin/scripts/severance-lib.sh disable=SC1091
source "$SCRIPT_DIR/severance-lib.sh"

input="$(cat)"
[ "$(sev_config_get SEVERANCE_ENABLED 0)" = "1" ] || exit 0

cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -n "$cwd" ] || cwd="$PWD"
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
# Per-session state (#15) keys on a real session id; without one we cannot write
# a schema-valid record (session_id is required, non-null). No id -> no-op.
[ -n "$session_id" ] || exit 0
slug="$(sev_slug "$cwd")"
sf="$(sev_project_state_file "$slug" "$session_id")"
prio="$(sev_config_get SEVERANCE_PRIORITY normal)"

usage_file="$(sev_state_dir)/usage.json"
signal_tier="$(jq -r '.signal_tier // empty' "$usage_file" 2>/dev/null || true)"
# Per-session cost (D6): prefer THIS session's file over the shared usage.json.
proj_cost=""
if [ -n "$session_id" ]; then
	scf="$(sev_session_cost_file "$session_id")"
	[ -f "$scf" ] && proj_cost="$(jq -r '.cost.total_cost_usd // empty' "$scf" 2>/dev/null || true)"
fi
[ -n "$proj_cost" ] || proj_cost="$(jq -r '.cost.total_cost_usd // empty' "$usage_file" 2>/dev/null || true)"

# shellcheck disable=SC2016  # $-names in the filter are jq variables (--arg), not shell
sev_state_merge "$sf" '
  . + {
    name:$n, cwd:$cwd,
    priority:(.priority // $p),
    session_id:$sid,
    session_cost_usd:(if $cost=="" then .session_cost_usd else ($cost|tonumber) end),
    signal_tier:(if $tier=="" then .signal_tier else $tier end),
    status:(if (.status=="severed" or .status=="paused") then .status else "active" end),
    paused:(.paused // false),
    ts:($ts|tonumber)
  }' \
	--arg n "$slug" --arg cwd "$cwd" --arg p "$prio" --arg sid "$session_id" \
	--arg cost "${proj_cost:-}" --arg tier "${signal_tier:-}" --arg ts "$(sev_now)" || true

exit 0
