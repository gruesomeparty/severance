#!/usr/bin/env bats
# Tests for gate.sh trip logic (PRD §5.2; AC1, AC2, AC4, AC5, AC10; R3).
# Signal is injected via a fresh usage.json (Tier-1) or a stubbed ccusage;
# OAuth is disabled so acquisition is deterministic.

load 'helpers/common'

setup() {
	sev_setup_tmp
	GATE="$SEV_SCRIPTS/gate.sh"
	CWD="$SEV_TMP/proj"
	mkdir -p "$CWD/.severance"
	export SEVERANCE_ENABLED=1
	export SEVERANCE_PRIORITY=normal
	export SEVERANCE_OAUTH_FALLBACK=0
	export SEVERANCE_CCUSAGE_CMD=false
	# Per-session state (#15): session_id "s1" from _hook, slug "proj" from cwd.
	SF="$SEVERANCE_STATE_DIR/projects/proj/s1.json"
}

teardown() {
	sev_teardown_tmp
}

# _usage <sess_util> <week_util> [used_credits] [cost] [tier]
_usage() {
	jq -n --argjson s "$1" --argjson w "$2" --argjson cred "${3:-null}" \
		--argjson cost "${4:-null}" --arg tier "${5:-statusline}" \
		--arg cwd "$CWD" --argjson ts "$(date +%s)" '
    {ts:$ts, signal_tier:$tier, rate_limits:null,
     normalized:{session:{utilization:$s,resets_at:"2026-07-02T18:00:00Z"},
                 weekly:{utilization:$w,resets_at:"2026-07-07T09:00:00Z"},
                 extra_usage:{is_enabled:($cred!=null), used_credits:$cred}},
     cost:{total_cost_usd:$cost}, session_id:"s1", model:"m", cwd:$cwd}' \
		>"$SEVERANCE_STATE_DIR/usage.json"
}

# _hook <tool_name> [file_path]
_hook() {
	jq -nc --arg t "$1" --arg fp "${2:-}" --arg cwd "$CWD" \
		'{hook_event_name:"PreToolUse", session_id:"s1", cwd:$cwd, tool_name:$t,
      tool_input: (if $fp=="" then {command:"ls"} else {file_path:$fp} end)}' \
		>"$SEV_TMP/in.json"
}

@test "AC2: disabled project is a provable no-op (exit 0, no state written)" {
	unset SEVERANCE_ENABLED
	_usage 99 99
	_hook Bash
	run "$GATE" <"$SEV_TMP/in.json"
	[ "$status" -eq 0 ]
	[ ! -f "$SF" ]
}

@test "AC1: session-threshold trip blocks with exit 2 + handover instruction + state" {
	_usage 85 40
	_hook Bash
	run "$GATE" <"$SEV_TMP/in.json"
	[ "$status" -eq 2 ]
	[[ "$output" == *"SEVERANCE"* ]]
	[[ "$output" == *".severance/handover.md"* ]]
	jq -e '.status=="severed" and .reason=="session_util" and .utilization_at_trip==85 and .resume_at=="2026-07-02T18:00:00Z"' "$SF"
}

@test "AC1: a write into .severance/ passes even while tripped" {
	_usage 85 40
	_hook Write "$CWD/.severance/handover.md"
	run "$GATE" <"$SEV_TMP/in.json"
	[ "$status" -eq 0 ]
}

@test "#15: first per-session write unlinks any legacy flat projects/<slug>.json" {
	# A pre-upgrade flat record for this slug exists...
	printf '%s' '{"name":"proj","cwd":"/x","status":"severed","priority":"normal","paused":false,"session_id":"old"}' \
		>"$SEVERANCE_STATE_DIR/projects/proj.json"
	_usage 10 10
	_hook Bash
	run "$GATE" <"$SEV_TMP/in.json"
	[ "$status" -eq 0 ]
	# ...it is gone (never read/migrated) and the per-session file now exists.
	[ ! -f "$SEVERANCE_STATE_DIR/projects/proj.json" ]
	[ -f "$SF" ]
}

@test "#15: two sessions of one slug keep independent per-session state files" {
	_usage 10 10
	_hook Bash
	run "$GATE" <"$SEV_TMP/in.json"
	[ "$status" -eq 0 ]
	# a second session (s2) of the SAME slug
	jq -nc --arg cwd "$CWD" \
		'{hook_event_name:"PreToolUse", session_id:"s2", cwd:$cwd, tool_name:"Bash", tool_input:{command:"ls"}}' \
		>"$SEV_TMP/in2.json"
	run "$GATE" <"$SEV_TMP/in2.json"
	[ "$status" -eq 0 ]
	[ -f "$SEVERANCE_STATE_DIR/projects/proj/s1.json" ]
	[ -f "$SEVERANCE_STATE_DIR/projects/proj/s2.json" ]
	jq -e '.session_id=="s1"' "$SEVERANCE_STATE_DIR/projects/proj/s1.json"
	jq -e '.session_id=="s2"' "$SEVERANCE_STATE_DIR/projects/proj/s2.json"
}

@test "gate state validates against the project-state schema" {
	_usage 85 40
	_hook Bash
	"$GATE" <"$SEV_TMP/in.json" || true
	run check-jsonschema --schemafile "$SEV_ROOT/schemas/project-state.schema.json" "$SF"
	[ "$status" -eq 0 ]
}

@test "AC10: 72% session utilization trips low and normal but not high" {
	_usage 72 40
	_hook Bash
	SEVERANCE_PRIORITY=low run "$GATE" <"$SEV_TMP/in.json"
	[ "$status" -eq 2 ]
	SEVERANCE_PRIORITY=normal run "$GATE" <"$SEV_TMP/in.json"
	[ "$status" -eq 2 ]
	SEVERANCE_PRIORITY=high run "$GATE" <"$SEV_TMP/in.json"
	[ "$status" -eq 0 ]
}

@test "AC10: explicit SEVERANCE_UTIL_PCT overrides the ladder (72% passes at 75)" {
	_usage 72 40
	_hook Bash
	SEVERANCE_PRIORITY=low SEVERANCE_UTIL_PCT=75 run "$GATE" <"$SEV_TMP/in.json"
	[ "$status" -eq 0 ]
}

@test "AC5: extra_usage credits trip regardless of priority; ALLOW flag disables" {
	_usage 5 5 12.5
	_hook Bash
	SEVERANCE_PRIORITY=critical run "$GATE" <"$SEV_TMP/in.json"
	[ "$status" -eq 2 ]
	jq -e '.reason=="extra_usage"' "$SF"
	SEVERANCE_PRIORITY=critical SEVERANCE_ALLOW_EXTRA_USAGE=1 run "$GATE" <"$SEV_TMP/in.json"
	[ "$status" -eq 0 ]
}

@test "critical never utilization-trips but the absolute cost cap still trips" {
	_usage 99 99 null 5.0
	_hook Bash
	SEVERANCE_PRIORITY=critical run "$GATE" <"$SEV_TMP/in.json"
	[ "$status" -eq 0 ]
	SEVERANCE_PRIORITY=critical SEVERANCE_LIMIT_USD=3 run "$GATE" <"$SEV_TMP/in.json"
	[ "$status" -eq 2 ]
	jq -e '.reason=="cost_limit"' "$SF"
}

@test "AC4: Tier-3 estimate gates conservatively at 60% of the cost cap" {
	export SEVERANCE_CCUSAGE_CMD='jq -nc "{blocks:[{costUSD:1.9,totalTokens:1,isActive:true}]}"'
	_hook Bash
	SEVERANCE_LIMIT_USD=3 run "$GATE" <"$SEV_TMP/in.json"
	[ "$status" -eq 2 ]
	jq -e '.reason=="cost_limit" and .signal_tier=="ccusage"' "$SF"
}

_session_cost() { # write THIS session's (s1) per-session cost file
	mkdir -p "$SEVERANCE_STATE_DIR/sessions"
	jq -n --argjson c "$1" --argjson ts "$(date +%s)" \
		'{ts:$ts, session_id:"s1", cost:{total_cost_usd:$c}}' \
		>"$SEVERANCE_STATE_DIR/sessions/s1.json"
}

@test "D6: cost cap uses THIS session's cost, not a sibling's in shared usage.json" {
	_usage 10 10 null 50.0 # usage.json (a sibling was last writer) says \$50
	_session_cost 2.0      # but this session has only spent \$2
	_hook Bash
	SEVERANCE_LIMIT_USD=5 run "$GATE" <"$SEV_TMP/in.json"
	[ "$status" -eq 0 ] # not severed: our \$2 < \$5 cap, despite usage.json's \$50
	_session_cost 6.0   # now this session itself exceeds the cap
	SEVERANCE_LIMIT_USD=5 run "$GATE" <"$SEV_TMP/in.json"
	[ "$status" -eq 2 ]
	jq -e '.reason=="cost_limit"' "$SF"
}

@test "limit_usd is refreshed on the no-trip path (display staleness fix)" {
	_usage 10 10
	_hook Bash
	SEVERANCE_LIMIT_USD=7 run "$GATE" <"$SEV_TMP/in.json"
	[ "$status" -eq 0 ]
	jq -e '.limit_usd == 7' "$SF"
}

@test "R3: consecutive blocks increment blocked_count and escalate at 5" {
	_usage 85 40
	_hook Bash
	local i
	for i in 1 2 3 4 5; do
		run "$GATE" <"$SEV_TMP/in.json"
		[ "$status" -eq 2 ]
	done
	jq -e '.blocked_count == 5' "$SF"
	[[ "$output" == *"repeated blocked calls (5)"* ]]
}

@test "R3: an allowed (untripped) call resets blocked_count" {
	_usage 85 40
	_hook Bash
	run "$GATE" <"$SEV_TMP/in.json"
	[ "$status" -eq 2 ]
	jq -e '.blocked_count == 1' "$SF"
	_usage 10 10
	run "$GATE" <"$SEV_TMP/in.json"
	[ "$status" -eq 0 ]
	jq -e '.blocked_count == 0' "$SF"
}

_hook_ss() {
	jq -nc --arg cwd "$CWD" \
		'{hook_event_name:"SessionStart", session_id:"s1", cwd:$cwd, source:"startup", model:"m"}' \
		>"$SEV_TMP/in.json"
}

@test "D2: SessionStart while severed cannot block (exit 0) but emits additionalContext" {
	_usage 85 40
	_hook_ss
	run "$GATE" --session-start <"$SEV_TMP/in.json"
	[ "$status" -eq 0 ]
	jq -e '.hookSpecificOutput.hookEventName=="SessionStart" and (.hookSpecificOutput.additionalContext | test("still severed"))' <<<"$output"
}

@test "SessionStart when healthy: exit 0, no additionalContext, active state" {
	_usage 10 10
	_hook_ss
	run "$GATE" --session-start <"$SEV_TMP/in.json"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	jq -e '.status=="active"' "$SF"
}
