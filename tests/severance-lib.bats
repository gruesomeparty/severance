#!/usr/bin/env bats
# Unit tests for the severance-lib.sh core: slug, state dir, config resolution,
# atomic writes, and the portable lock.

load 'helpers/common'

setup() {
	sev_setup_tmp
	source "$SEV_LIB"
}

teardown() {
	sev_teardown_tmp
}

@test "sev_slug: basename of a normal path" {
	run sev_slug "/home/berkay/dev/one-ocean-cms"
	[ "$status" -eq 0 ]
	[ "$output" = "one-ocean-cms" ]
}

@test "sev_slug: trailing slash is ignored" {
	run sev_slug "/home/berkay/dev/one-ocean-cms/"
	[ "$output" = "one-ocean-cms" ]
}

@test "sev_slug: unsafe characters are sanitized and collapsed" {
	run sev_slug "/tmp/My Project! v2"
	[ "$output" = "My-Project-v2" ]
}

@test "sev_state_dir: honors SEVERANCE_STATE_DIR" {
	run sev_state_dir
	[ "$output" = "$SEVERANCE_STATE_DIR" ]
}

@test "sev_state_dir: defaults under HOME when unset" {
	unset SEVERANCE_STATE_DIR
	HOME=/tmp/fakehome run sev_state_dir
	[ "$output" = "/tmp/fakehome/.claude/severance" ]
}

@test "sev_config_get: environment value wins" {
	export SEVERANCE_MAX_RESUMES=5
	run sev_config_get SEVERANCE_MAX_RESUMES 3
	[ "$output" = "5" ]
}

@test "sev_config_get: falls back to config.json defaults block" {
	unset SEVERANCE_MAX_RESUMES
	cp "$SEV_FIXTURES/config/valid/with-defaults.json" "$SEVERANCE_STATE_DIR/config.json"
	run sev_config_get SEVERANCE_MAX_RESUMES 3
	[ "$output" = "5" ]
}

@test "sev_config_get: built-in default when nothing set" {
	unset SEVERANCE_MAX_RESUMES
	run sev_config_get SEVERANCE_MAX_RESUMES 3
	[ "$output" = "3" ]
}

@test "sev_atomic_write: writes stdin content verbatim" {
	f="$SEV_TMP/out.json"
	printf '%s' '{"a":1}' | sev_atomic_write "$f"
	[ "$(cat "$f")" = '{"a":1}' ]
}

@test "sev_atomic_write: concurrent writers never interleave (file stays valid JSON)" {
	f="$SEV_TMP/race.json"
	for i in $(seq 1 20); do
		printf '{"n":%d}' "$i" | sev_atomic_write "$f" &
	done
	wait
	run jq -e . "$f"
	[ "$status" -eq 0 ]
}

@test "sev_locked: runs the command and returns its exit status" {
	run sev_locked "$SEV_TMP/a.lock" true
	[ "$status" -eq 0 ]
	run sev_locked "$SEV_TMP/a.lock" false
	[ "$status" -ne 0 ]
}

@test "sev_locked: serializes a parallel read-modify-write with no lost updates" {
	lock="$SEV_TMP/c.lock"
	export CNT="$SEV_TMP/counter"
	echo 0 >"$CNT"
	inc() { sev_locked "$lock" sh -c 'v=$(cat "$CNT"); echo $((v + 1)) >"$CNT"'; }
	for _ in $(seq 1 15); do inc & done
	wait
	[ "$(cat "$CNT")" = "15" ]
}
