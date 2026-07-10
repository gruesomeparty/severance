#!/usr/bin/env bats
# Tests for session-end.sh (SessionEnd cleanup hook, issue #15): remove THIS
# session's project-state file and prune the emptied <slug>/ directory, while a
# sibling session's file (and its non-empty directory) survives.

load 'helpers/common'

setup() {
	sev_setup_tmp
	SE="$SEV_SCRIPTS/session-end.sh"
	CWD="$SEV_TMP/proj"
	mkdir -p "$CWD"
	export SEVERANCE_ENABLED=1
	PROJ="$SEVERANCE_STATE_DIR/projects"
	source "$SEV_LIB"
}

teardown() {
	sev_teardown_tmp
}

# _end <session_id> — feed a SessionEnd payload for this cwd/session on stdin.
_end() {
	jq -nc --arg cwd "$CWD" --arg sid "$1" \
		'{hook_event_name:"SessionEnd", session_id:$sid, cwd:$cwd, reason:"other"}' \
		>"$SEV_TMP/in.json"
}

_mkstate() { # <session_id>
	mkdir -p "$PROJ/proj"
	jq -n --arg sid "$1" --arg c "$CWD" \
		'{name:"proj", cwd:$c, status:"active", priority:"normal", paused:false, session_id:$sid}' \
		>"$PROJ/proj/$1.json"
}

@test "SessionEnd: disabled project is a no-op (state untouched)" {
	unset SEVERANCE_ENABLED
	_mkstate s1
	_end s1
	run "$SE" <"$SEV_TMP/in.json"
	[ "$status" -eq 0 ]
	[ -f "$PROJ/proj/s1.json" ]
}

@test "SessionEnd: removes this session's file and prunes the emptied slug dir" {
	_mkstate s1
	_end s1
	run "$SE" <"$SEV_TMP/in.json"
	[ "$status" -eq 0 ]
	[ ! -f "$PROJ/proj/s1.json" ]
	[ ! -d "$PROJ/proj" ]
}

@test "SessionEnd: a sibling session's file and its directory survive" {
	_mkstate s1
	_mkstate s2
	_end s1
	run "$SE" <"$SEV_TMP/in.json"
	[ "$status" -eq 0 ]
	[ ! -f "$PROJ/proj/s1.json" ]
	[ -f "$PROJ/proj/s2.json" ]
	[ -d "$PROJ/proj" ]
}

@test "SessionEnd: resilient to an already-absent file (no error)" {
	_end s1
	run "$SE" <"$SEV_TMP/in.json"
	[ "$status" -eq 0 ]
}

@test "SessionEnd: no session_id on stdin is a safe no-op" {
	_mkstate s1
	jq -nc --arg cwd "$CWD" '{hook_event_name:"SessionEnd", cwd:$cwd, reason:"other"}' >"$SEV_TMP/in.json"
	run "$SE" <"$SEV_TMP/in.json"
	[ "$status" -eq 0 ]
	[ -f "$PROJ/proj/s1.json" ]
}
