#!/usr/bin/env bats
# Tests for the ladder resolution and project-state read-modify-write helpers
# (PRD §5.4, §6.2).

load 'helpers/common'

setup() {
	sev_setup_tmp
	source "$SEV_LIB"
}

teardown() {
	sev_teardown_tmp
}

@test "sev_ladder: built-in defaults when no config exists" {
	[ "$(sev_ladder high session)" = "85" ]
	[ "$(sev_ladder high weekly)" = "95" ]
	[ "$(sev_ladder high reserve)" = "60" ]
	[ "$(sev_ladder normal session)" = "70" ]
	[ "$(sev_ladder normal reserve)" = "null" ]
	[ "$(sev_ladder low session)" = "50" ]
	[ "$(sev_ladder critical session)" = "null" ]
	[ "$(sev_ladder critical reserve)" = "null" ]
}

@test "sev_ladder: config.json overrides the built-ins" {
	cp "$SEV_FIXTURES/config/valid/with-defaults.json" "$SEVERANCE_STATE_DIR/config.json"
	[ "$(sev_ladder high session)" = "80" ]
	[ "$(sev_ladder high reserve)" = "55" ]
	[ "$(sev_ladder low weekly)" = "65" ]
}

@test "sev_ladder: an explicit null in config disables that gate (not built-in)" {
	printf '%s' '{"ladder":{"critical":{"session":null,"weekly":null,"reserve":null},"high":{"session":null,"weekly":95,"reserve":60},"normal":{"session":70,"weekly":85,"reserve":null},"low":{"session":50,"weekly":70,"reserve":null}}}' >"$SEVERANCE_STATE_DIR/config.json"
	[ "$(sev_ladder high session)" = "null" ]
	[ "$(sev_ladder high weekly)" = "95" ]
}

@test "sev_project_state_file: lives under <state>/projects/<slug>/<session_id>.json" {
	[ "$(sev_project_state_file myproj sess-123)" = "$SEVERANCE_STATE_DIR/projects/myproj/sess-123.json" ]
}

@test "sev_project_state_file: sanitizes unsafe characters in the session id" {
	[ "$(sev_project_state_file myproj 'a/b c')" = "$SEVERANCE_STATE_DIR/projects/myproj/a-b-c.json" ]
}

@test "sev_session_cost_file: lives under <state>/sessions/<session_id>.json" {
	[ "$(sev_session_cost_file 9359d2c5-abc)" = "$SEVERANCE_STATE_DIR/sessions/9359d2c5-abc.json" ]
}

@test "sev_session_cost_file: sanitizes unsafe characters in the session id" {
	[ "$(sev_session_cost_file 'a/b c')" = "$SEVERANCE_STATE_DIR/sessions/a-b-c.json" ]
}

@test "sev_state_merge: creates then merges without clobbering existing fields" {
	sf="$SEVERANCE_STATE_DIR/projects/p.json"
	sev_state_merge "$sf" '. + {name:$n, resume_count:1}' --arg n "p"
	jq -e '.name == "p" and .resume_count == 1' "$sf"
	sev_state_merge "$sf" '. + {status:$s}' --arg s "severed"
	jq -e '.status == "severed" and .resume_count == 1 and .name == "p"' "$sf"
}

@test "sev_state_merge: resets an unparseable state file to {} before merging" {
	sf="$SEVERANCE_STATE_DIR/projects/bad.json"
	printf '%s' '{ corrupt' >"$sf"
	sev_state_merge "$sf" '. + {status:$s}' --arg s "active"
	jq -e '.status == "active"' "$sf"
}

@test "sev_state_merge: concurrent read-modify-write loses no updates" {
	sf="$SEVERANCE_STATE_DIR/projects/c.json"
	sev_state_merge "$sf" '. + {n:0}'
	for _ in $(seq 1 10); do
		sev_state_merge "$sf" '.n += 1' &
	done
	wait
	jq -e '.n == 10' "$sf"
}
