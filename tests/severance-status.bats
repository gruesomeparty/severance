#!/usr/bin/env bats
# Tests for severance-status.sh (the /severance:severance-status backend).

load 'helpers/common'

setup() {
	sev_setup_tmp
	STATUS="$SEV_SCRIPTS/severance-status.sh"
}

teardown() {
	sev_teardown_tmp
}

@test "status: graceful when there is no state" {
	run "$STATUS"
	[ "$status" -eq 0 ]
	[[ "$output" == *"no usage cache"* ]]
	[[ "$output" == *"(none tracked)"* ]]
}

@test "status: prints signal, quotas, and per-project summary" {
	jq -n --argjson ts "$(date +%s)" '
    {ts:$ts, signal_tier:"statusline", rate_limits:null,
     normalized:{session:{utilization:62,resets_at:"2026-07-02T18:00:00Z"},
                 weekly:{utilization:41,resets_at:"2026-07-07T09:00:00Z"},
                 extra_usage:{is_enabled:null,used_credits:null}},
     cost:{total_cost_usd:1.42}, session_id:"s", model:"m", cwd:"x"}' \
		>"$SEVERANCE_STATE_DIR/usage.json"
	mkdir -p "$SEVERANCE_STATE_DIR/projects/one-ocean-cms"
	jq -n '{name:"one-ocean-cms", cwd:"/x", status:"severed", reason:"session_util", priority:"normal", paused:false, session_id:"sess-1", resume_at:"2026-07-02T18:00:00Z", resume_count:1}' \
		>"$SEVERANCE_STATE_DIR/projects/one-ocean-cms/sess-1.json"
	run "$STATUS"
	[ "$status" -eq 0 ]
	[[ "$output" == *"signal: statusline"* ]]
	[[ "$output" == *"5h refinement quota: 62%"* ]]
	[[ "$output" == *"one-ocean-cms"* ]]
	[[ "$output" == *"severed"* ]]
	[[ "$output" == *"resumes 2026-07-02T18:00:00Z"* ]]
}

@test "status: surfaces used credits when present" {
	jq -n --argjson ts "$(date +%s)" '
    {ts:$ts, signal_tier:"oauth", rate_limits:null,
     normalized:{session:{utilization:12,resets_at:null},weekly:{utilization:8,resets_at:null},
                 extra_usage:{is_enabled:true,used_credits:12.5}},
     cost:null, session_id:null, model:null, cwd:null}' \
		>"$SEVERANCE_STATE_DIR/usage.json"
	run "$STATUS"
	[ "$status" -eq 0 ]
	[[ "$output" == *"usage credits consumed: 12.5"* ]]
}
