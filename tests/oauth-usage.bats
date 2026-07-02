#!/usr/bin/env bats
# Tests for oauth-usage.sh (Tier-2, PRD §3/§9.2): fetch the OAuth usage endpoint
# with caching + token from a (fake) credentials file, and fall through silently
# on any non-200/parse/timeout. Never persists the token.

load 'helpers/common'

setup() {
	sev_setup_tmp
	OAUTH="$SEV_SCRIPTS/oauth-usage.sh"
	PORTFILE="$SEV_TMP/port"
	python3 "$SEV_ROOT/tests/helpers/mock-oauth-server.py" "$PORTFILE" &
	MOCK_PID=$!
	local i
	for i in $(seq 1 50); do
		[ -s "$PORTFILE" ] && break
		sleep 0.1
	done
	BASE="http://127.0.0.1:$(cat "$PORTFILE")"
	printf '%s' '{"claudeAiOauth":{"accessToken":"faketoken-XYZ"}}' >"$SEV_TMP/creds.json"
	export SEVERANCE_CREDENTIALS_FILE="$SEV_TMP/creds.json"
	export SEVERANCE_OAUTH_TIMEOUT=2
}

teardown() {
	[ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null
	sev_teardown_tmp
}

@test "oauth: 200 good returns the usage JSON, exit 0" {
	export SEVERANCE_OAUTH_URL="$BASE/good"
	run "$OAUTH"
	[ "$status" -eq 0 ]
	jq -e '.five_hour.utilization == 37.0 and .extra_usage.is_enabled == false' <<<"$output"
}

@test "oauth: 200 with used_credits > 0 is surfaced" {
	export SEVERANCE_OAUTH_URL="$BASE/extra"
	run "$OAUTH"
	[ "$status" -eq 0 ]
	jq -e '.extra_usage.used_credits == 12.5' <<<"$output"
}

@test "oauth: 401 falls through (non-zero exit, no usable JSON)" {
	export SEVERANCE_OAUTH_URL="$BASE/401"
	run "$OAUTH"
	[ "$status" -ne 0 ]
}

@test "oauth: malformed 200 body fails (parse error -> fall through)" {
	export SEVERANCE_OAUTH_URL="$BASE/malformed"
	run "$OAUTH"
	[ "$status" -ne 0 ]
}

@test "oauth: timeout falls through within the client timeout" {
	export SEVERANCE_OAUTH_URL="$BASE/timeout"
	run "$OAUTH"
	[ "$status" -ne 0 ]
}

@test "oauth: missing token fails without hitting the network" {
	export SEVERANCE_OAUTH_URL="$BASE/good"
	export SEVERANCE_CREDENTIALS_FILE="$SEV_TMP/does-not-exist.json"
	run "$OAUTH"
	[ "$status" -ne 0 ]
}

@test "oauth: within 60s the cached response is served (no refetch)" {
	export SEVERANCE_OAUTH_URL="$BASE/good"
	run "$OAUTH"
	[ "$status" -eq 0 ]
	# Now point at /401; a fresh fetch would fail, but the <60s cache must answer.
	export SEVERANCE_OAUTH_URL="$BASE/401"
	run "$OAUTH"
	[ "$status" -eq 0 ]
	jq -e '.five_hour.utilization == 37.0' <<<"$output"
}

@test "oauth: the access token is never persisted to the state dir" {
	export SEVERANCE_OAUTH_URL="$BASE/good"
	run "$OAUTH"
	[ "$status" -eq 0 ]
	run grep -rl "faketoken-XYZ" "$SEVERANCE_STATE_DIR"
	[ "$status" -ne 0 ] # grep -l finds nothing -> non-zero
}
