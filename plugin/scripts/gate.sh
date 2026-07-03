#!/usr/bin/env bash
# gate.sh — Severance budget gate (PRD §5.2).
#
# Registered on PreToolUse (blocks the tool call with exit 2 + a handover
# instruction on stderr) and on SessionStart (--session-start; can't block via
# exit 2 per current docs — D2 — so it emits additionalContext instead; real
# enforcement stays on the PreToolUse gate at the first tool call).
#
# Installing the plugin is a no-op until a project sets SEVERANCE_ENABLED=1 (G4).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugin/scripts/severance-lib.sh disable=SC1091
source "$SCRIPT_DIR/severance-lib.sh"

mode="pretooluse"
[ "${1:-}" = "--session-start" ] && mode="session-start"

input="$(cat)"

# 1. Enablement — plugin installed but not enabled here is a provable no-op.
[ "$(sev_config_get SEVERANCE_ENABLED 0)" = "1" ] || exit 0

# ---- parse hook input -------------------------------------------------------
_j() { printf '%s' "$input" | jq -r "$1" 2>/dev/null || true; }
cwd="$(_j '.cwd // empty')"
[ -n "$cwd" ] || cwd="$PWD"
session_id="$(_j '.session_id // empty')"
file_path="$(_j '.tool_input.file_path // empty')"
slug="$(sev_slug "$cwd")"
sf="$(sev_project_state_file "$slug")"

# ---- resolve config / effective thresholds ----------------------------------
prio="$(sev_config_get SEVERANCE_PRIORITY normal)"
sess_thr="$(sev_config_get SEVERANCE_UTIL_PCT "$(sev_ladder "$prio" session)")"
week_thr="$(sev_config_get SEVERANCE_WEEKLY_PCT "$(sev_ladder "$prio" weekly)")"
limit_usd="$(sev_config_get SEVERANCE_LIMIT_USD "")"
allow_extra="$(sev_config_get SEVERANCE_ALLOW_EXTRA_USAGE 0)"
max_resumes="$(sev_config_get SEVERANCE_MAX_RESUMES 3)"

_ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a + 0 >= b + 0)}'; }
_gt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a + 0 > b + 0)}'; }

# Handover whitelist: writes into .severance/ are allowed even while tripped, so
# the agent can comply with the "write your handover" instruction (§5.2 edge case).
handover_write=0
case "$file_path" in
*/.severance/*) handover_write=1 ;;
esac

# ---- acquire signal ---------------------------------------------------------
signal="$(sev_acquire || true)"
_s() { printf '%s' "$signal" | jq -r "$1" 2>/dev/null || true; }
sess_util="$(_s '.normalized.session.utilization // empty')"
week_util="$(_s '.normalized.weekly.utilization // empty')"
resets_at="$(_s '.normalized.session.resets_at // empty')"
signal_tier="$(_s '.signal_tier // "none"')"
used_credits="$(_s '.normalized.extra_usage.used_credits // empty')"

usage_file="$(sev_state_dir)/usage.json"
# Cost is per-session (D6): read THIS session's cost first; fall back to the
# shared usage.json only when there is no per-session record (single-session case).
proj_cost=""
if [ -n "$session_id" ]; then
	scf="$(sev_session_cost_file "$session_id")"
	[ -f "$scf" ] && proj_cost="$(jq -r '.cost.total_cost_usd // empty' "$scf" 2>/dev/null || true)"
fi
[ -n "$proj_cost" ] || proj_cost="$(jq -r '.cost.total_cost_usd // empty' "$usage_file" 2>/dev/null || true)"

# Tier-3 estimates gate conservatively: trip the cost cap at 60% of the ceiling.
cost_thr="$limit_usd"
if [ -n "$limit_usd" ] && [ "$signal_tier" = "ccusage" ]; then
	cost_thr="$(awk -v l="$limit_usd" 'BEGIN{printf "%.4f", l * 0.6}')"
fi

# ---- existing project state -------------------------------------------------
existing_paused="$(jq -r '.paused // false' "$sf" 2>/dev/null || echo false)"
existing_reason="$(jq -r '.reason // empty' "$sf" 2>/dev/null || true)"
existing_resume_count="$(jq -r '.resume_count // 0' "$sf" 2>/dev/null || echo 0)"
existing_blocked="$(jq -r '.blocked_count // 0' "$sf" 2>/dev/null || echo 0)"
existing_preempted_by="$(jq -r '.preempted_by // empty' "$sf" 2>/dev/null || true)"

# ---- evaluate trip conditions (OR) ------------------------------------------
trip=0
reason=""
util_at_trip=""
if [ "$existing_paused" = "true" ]; then
	trip=1
	reason="${existing_reason:-manual}"
fi
if [ "$trip" -eq 0 ] && [ -n "$sess_util" ] && [ "$sess_thr" != "null" ] && [ -n "$sess_thr" ] && _ge "$sess_util" "$sess_thr"; then
	trip=1
	reason="session_util"
	util_at_trip="$sess_util"
fi
if [ "$trip" -eq 0 ] && [ -n "$week_util" ] && [ "$week_thr" != "null" ] && [ -n "$week_thr" ] && _ge "$week_util" "$week_thr"; then
	trip=1
	reason="weekly_util"
	util_at_trip="$week_util"
fi
if [ "$trip" -eq 0 ] && [ -n "$limit_usd" ] && [ -n "$proj_cost" ] && _ge "$proj_cost" "$cost_thr"; then
	trip=1
	reason="cost_limit"
fi
if [ "$trip" -eq 0 ] && [ "$allow_extra" != "1" ] && [ -n "$used_credits" ] && _gt "$used_credits" 0; then
	trip=1
	reason="extra_usage"
fi

# ---- not tripped: defend headroom, refresh active state, allow --------------
if [ "$trip" -eq 0 ]; then
	sev_preempt_sweep "$slug" "$prio" "$sess_util" || true
	# shellcheck disable=SC2016  # $-names in the filter are jq variables (--arg), not shell
	sev_state_merge "$sf" '
    . + {
      name:$n, cwd:$cwd, priority:$p, status:"active", paused:false, reason:null, preempted_by:null,
      session_cost_usd:(if $cost=="" then null else ($cost|tonumber) end),
      limit_usd:(if $limit=="" then null else ($limit|tonumber) end),
      signal_tier:(if $tier=="none" or $tier=="" then null else $tier end),
      session_id:(if $sid=="" then null else $sid end),
      blocked_count:0, ts:($ts|tonumber)
    }' \
		--arg n "$slug" --arg cwd "$cwd" --arg p "$prio" --arg cost "${proj_cost:-}" \
		--arg limit "${limit_usd:-}" --arg tier "$signal_tier" --arg sid "$session_id" --arg ts "$(sev_now)" || true
	exit 0
fi

# ---- tripped ----------------------------------------------------------------
# Always let the handover write through.
if [ "$handover_write" -eq 1 ]; then
	exit 0
fi

case "$reason" in
preempted | manual)
	status="paused"
	paused_flag="true"
	;;
*)
	status="severed"
	paused_flag="false"
	;;
esac

if [ "$mode" = "pretooluse" ]; then
	blocked=$((existing_blocked + 1))
else
	blocked="$existing_blocked"
fi

severed_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# shellcheck disable=SC2016  # $-names in the filter are jq variables (--arg), not shell
sev_state_merge "$sf" '
  . + {
    name:$n, cwd:$cwd, priority:$p, status:$st, reason:$r, paused:($paused=="true"),
    session_cost_usd:(if $cost=="" then null else ($cost|tonumber) end),
    limit_usd:(if $limit=="" then null else ($limit|tonumber) end),
    utilization_at_trip:(if $uat=="" then null else ($uat|tonumber) end),
    signal_tier:(if $tier=="none" or $tier=="" then null else $tier end),
    tmux_pane:(if $pane=="" then null else $pane end),
    session_id:(if $sid=="" then null else $sid end),
    severed_at:$sev,
    resume_at:(if $resume=="" then null else $resume end),
    resume_count:($rc|tonumber), blocked_count:($blocked|tonumber), ts:($ts|tonumber)
  }' \
	--arg n "$slug" --arg cwd "$cwd" --arg p "$prio" --arg st "$status" --arg r "$reason" \
	--arg paused "$paused_flag" --arg cost "${proj_cost:-}" --arg limit "${limit_usd:-}" \
	--arg uat "${util_at_trip:-}" --arg tier "$signal_tier" --arg pane "${TMUX_PANE:-}" \
	--arg sid "$session_id" --arg sev "$severed_iso" --arg resume "${resets_at:-}" \
	--arg rc "$existing_resume_count" --arg blocked "$blocked" --arg ts "$(sev_now)" || true

# Schedule the auto-resume (Linux); bounded by max resumes and the R3 escalation.
escalated=0
[ "$blocked" -ge 5 ] && escalated=1
if [ "$status" = "severed" ] && [ "$existing_resume_count" -lt "$max_resumes" ] && [ "$escalated" -eq 0 ]; then
	"$SEV_SELF_DIR/schedule-resume.sh" "$sf" >/dev/null 2>&1 || true
fi

# ---- build the message ------------------------------------------------------
case "$reason" in
session_util) head="session window at ${sess_util}% (limit ${sess_thr}% for priority ${prio})" ;;
weekly_util) head="weekly window at ${week_util}% (limit ${week_thr}% for priority ${prio})" ;;
cost_limit) head="session cost \$${proj_cost} reached the \$${limit_usd} cap" ;;
extra_usage) head="usage credits are being consumed (${used_credits}) — the exact event Severance prevents" ;;
preempted) head="preempted by higher-priority work${existing_preempted_by:+ (${existing_preempted_by})}" ;;
manual) head="manually paused" ;;
*) head="budget gate tripped" ;;
esac

if [ "$mode" = "session-start" ]; then
	scmsg="SEVERANCE [$reason]: this project is still severed until ${resets_at:-the next window reset}. Do not start new work — the first tool call will be gated."
	jq -n --arg c "$scmsg" '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$c}}'
	exit 0
fi

msg="SEVERANCE [$reason]: ${head}. Write a concise handover of current task state, next steps, and open questions to .severance/handover.md now, then stop. Do not call further tools after writing the handover. Resume is scheduled for ${resets_at:-the next window reset}."
if [ "$escalated" -eq 1 ]; then
	msg="$msg [SEVERANCE: repeated blocked calls (${blocked}) — stop calling tools and end the turn; auto-resume is paused for this session.]"
fi
printf '%s\n' "$msg" >&2
exit 2
