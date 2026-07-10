#!/usr/bin/env bats
# Tests for headroom preemption (PRD §5.5/§5.6; AC11; R5 throttle).

load 'helpers/common'

setup() {
	sev_setup_tmp
	GATE="$SEV_SCRIPTS/gate.sh"
	export SEVERANCE_ENABLED=1
	export SEVERANCE_OAUTH_FALLBACK=0
	export SEVERANCE_CCUSAGE_CMD=false
	# session 65 (>= high reserve 60, < high threshold 85), weekly 30
	jq -n --argjson ts "$(date +%s)" '
    {ts:$ts, signal_tier:"statusline", rate_limits:null,
     normalized:{session:{utilization:65,resets_at:"2026-07-02T18:00:00Z"},
                 weekly:{utilization:30,resets_at:null},
                 extra_usage:{is_enabled:null,used_credits:null}},
     cost:{total_cost_usd:null}, session_id:"h", model:"m", cwd:"x"}' \
		>"$SEVERANCE_STATE_DIR/usage.json"
	PROJ="$SEVERANCE_STATE_DIR/projects"
}

teardown() {
	sev_teardown_tmp
}

_mkstate() { # <slug> <priority> <status> [session_id]
	local sid="${4:-s}"
	mkdir -p "$PROJ/$1"
	jq -n --arg n "$1" --arg c "/x/$1" --arg p "$2" --arg s "$3" --arg sid "$sid" \
		'{name:$n, cwd:$c, status:$s, priority:$p, paused:($s=="paused"), session_id:$sid, resume_count:0}' \
		>"$PROJ/$1/$sid.json"
}

_run_high_preemptor() {
	local cwd="$SEV_TMP/high-proj"
	mkdir -p "$cwd"
	jq -nc --arg cwd "$cwd" \
		'{hook_event_name:"PreToolUse", session_id:"h", cwd:$cwd, tool_name:"Bash", tool_input:{command:"ls"}}' \
		>"$SEV_TMP/in.json"
	SEVERANCE_PRIORITY=high run "$GATE" <"$SEV_TMP/in.json"
}

@test "AC11: high-prio at util>=reserve preempts an enabled normal project; critical untouched" {
	_mkstate normal-proj normal active
	_mkstate crit-proj critical active
	_run_high_preemptor
	[ "$status" -eq 0 ] # the high preemptor itself does not trip at 65
	jq -e '.paused==true and .reason=="preempted" and .preempted_by=="high-proj" and .status=="paused"' "$PROJ/normal-proj/s.json"
	jq -e '.status=="active" and .paused==false' "$PROJ/crit-proj/s.json"
	run check-jsonschema --schemafile "$SEV_ROOT/schemas/project-state.schema.json" "$PROJ/normal-proj/s.json"
	[ "$status" -eq 0 ]
}

@test "#15: preemption is per-session — a sibling session of the preemptor's slug is untouched" {
	_mkstate normal-proj normal active
	# The preemptor slug (high-proj) has a second, concurrent session: it must NOT
	# be preempted by its own sweep (same slug, same priority).
	_mkstate high-proj high active h2
	_run_high_preemptor
	[ "$status" -eq 0 ]
	jq -e '.paused==true and .status=="paused"' "$PROJ/normal-proj/s.json"
	jq -e '.status=="active" and .paused==false' "$PROJ/high-proj/h2.json"
}

@test "AC11: a preempted project trips within one PreToolUse (reason=preempted)" {
	local cwd="$SEV_TMP/normal-proj"
	mkdir -p "$cwd/.severance" "$PROJ/normal-proj"
	jq -n --arg c "$cwd" \
		'{name:"normal-proj", cwd:$c, status:"paused", priority:"normal", paused:true, reason:"preempted", preempted_by:"high-proj", session_id:"n", resume_count:0}' \
		>"$PROJ/normal-proj/n.json"
	jq -nc --arg cwd "$cwd" \
		'{hook_event_name:"PreToolUse", session_id:"n", cwd:$cwd, tool_name:"Bash", tool_input:{command:"ls"}}' \
		>"$SEV_TMP/in.json"
	SEVERANCE_PRIORITY=normal run "$GATE" <"$SEV_TMP/in.json"
	[ "$status" -eq 2 ]
	[[ "$output" == *"preempted"* ]]
}

@test "preemption never touches equal/higher priority or already-severed projects" {
	_mkstate high2 high active
	_mkstate low-sev low severed
	_run_high_preemptor
	jq -e '.paused==false and .status=="active"' "$PROJ/high2/s.json"
	jq -e '.status=="severed" and .paused==false' "$PROJ/low-sev/s.json"
}

@test "R5: the preemption sweep is throttled to once per 60s per preemptor" {
	_mkstate normal-proj normal active
	_run_high_preemptor
	jq -e '.preempt_sweep_ts != null and .preempt_sweep_ts > 0' "$PROJ/high-proj/h.json"
	# clear the pause, run again immediately -> throttled, so it is NOT re-paused
	jq '.paused=false | .status="active" | .reason=null | .preempted_by=null' "$PROJ/normal-proj/s.json" >"$SEV_TMP/np" && mv "$SEV_TMP/np" "$PROJ/normal-proj/s.json"
	_run_high_preemptor
	jq -e '.paused==false' "$PROJ/normal-proj/s.json"
}
