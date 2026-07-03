#!/usr/bin/env bats
# Tests for heartbeat.sh (Stop hook, PRD §5.1): refresh cost/ts, preserve a
# severed/paused status.

load 'helpers/common'

setup() {
	sev_setup_tmp
	HB="$SEV_SCRIPTS/heartbeat.sh"
	CWD="$SEV_TMP/proj"
	mkdir -p "$CWD"
	export SEVERANCE_ENABLED=1
	export SEVERANCE_PRIORITY=normal
	SF="$SEVERANCE_STATE_DIR/projects/proj.json"
}

teardown() {
	sev_teardown_tmp
}

_usage_cost() {
	jq -n --argjson c "$1" --argjson ts "$(date +%s)" \
		'{ts:$ts, signal_tier:"statusline", rate_limits:null,
      normalized:{session:{utilization:10,resets_at:null},weekly:{utilization:10,resets_at:null},extra_usage:{is_enabled:null,used_credits:null}},
      cost:{total_cost_usd:$c}, session_id:"s1", model:"m", cwd:"x"}' \
		>"$SEVERANCE_STATE_DIR/usage.json"
}

_stop() {
	jq -nc --arg cwd "$CWD" '{hook_event_name:"Stop", session_id:"s1", cwd:$cwd}' >"$SEV_TMP/in.json"
}

@test "heartbeat: disabled project is a no-op" {
	unset SEVERANCE_ENABLED
	_usage_cost 1.5
	_stop
	run "$HB" <"$SEV_TMP/in.json"
	[ "$status" -eq 0 ]
	[ ! -f "$SF" ]
}

@test "heartbeat: refreshes session_cost_usd + ts and marks active on a fresh project" {
	_usage_cost 1.5
	_stop
	run "$HB" <"$SEV_TMP/in.json"
	[ "$status" -eq 0 ]
	jq -e '.name=="proj" and .session_cost_usd==1.5 and .status=="active" and .priority=="normal"' "$SF"
	run check-jsonschema --schemafile "$SEV_ROOT/schemas/project-state.schema.json" "$SF"
	[ "$status" -eq 0 ]
}

@test "heartbeat: preserves a severed status while updating cost" {
	jq -n --arg cwd "$CWD" \
		'{name:"proj", cwd:$cwd, status:"severed", reason:"session_util", priority:"normal", paused:false, resume_count:1}' \
		>"$SF"
	_usage_cost 2.0
	_stop
	run "$HB" <"$SEV_TMP/in.json"
	[ "$status" -eq 0 ]
	jq -e '.status=="severed" and .session_cost_usd==2.0 and .resume_count==1 and .reason=="session_util"' "$SF"
}
