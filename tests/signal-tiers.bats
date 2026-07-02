#!/usr/bin/env bats
# Tests for sev_acquire tier selection (PRD §3/§5.2/§9.2): statusline cache >
# OAuth > ccusage, with signal_tier recorded, and graceful degradation.

load 'helpers/common'

setup() {
	sev_setup_tmp
	source "$SEV_LIB"
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
	CCUSAGE_OK="cat '$SEV_FIXTURES/signal/ccusage-active.json'"
}

teardown() {
	[ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null
	sev_teardown_tmp
}

_stale_statusline() {
	jq -n --argjson u "$1" '{
    ts: 1, signal_tier: "statusline", rate_limits: null,
    normalized: {
      session: {utilization: $u, resets_at: null},
      weekly:  {utilization: $u, resets_at: null},
      extra_usage: {is_enabled: null, used_credits: null}
    },
    cost: null, session_id: null, model: null, cwd: null
  }' >"$SEVERANCE_STATE_DIR/usage.json"
}

@test "tier: fresh statusline cache wins without touching the network" {
	"$SEV_SCRIPTS/statusline-bridge.sh" <"$SEV_FIXTURES/signal/statusline-stdin.json" >/dev/null
	export SEVERANCE_OAUTH_URL="$BASE/401" # would fail if consulted
	run sev_acquire
	[ "$status" -eq 0 ]
	jq -e '.signal_tier == "statusline" and .normalized.session.utilization == 23.5' <<<"$output"
}

@test "tier: stale statusline -> OAuth fallback, records signal_tier=oauth" {
	_stale_statusline 99
	export SEVERANCE_OAUTH_URL="$BASE/good"
	run sev_acquire
	[ "$status" -eq 0 ]
	jq -e '.signal_tier == "oauth" and .normalized.session.utilization == 37.0' <<<"$output"
	jq -e '.signal_tier == "oauth"' "$SEVERANCE_STATE_DIR/usage.json"
}

@test "tier: OAuth disabled -> ccusage estimate (signal_tier=ccusage, util null)" {
	export SEVERANCE_OAUTH_FALLBACK=0
	export SEVERANCE_CCUSAGE_CMD="$CCUSAGE_OK"
	run sev_acquire
	[ "$status" -eq 0 ]
	jq -e '.signal_tier == "ccusage" and .cost.total_cost_usd == 2.75 and .normalized.session.utilization == null' <<<"$output"
	jq -e '.signal_tier == "ccusage"' "$SEVERANCE_STATE_DIR/usage.json"
}

@test "tier: OAuth 401 -> ccusage estimate" {
	export SEVERANCE_OAUTH_URL="$BASE/401"
	export SEVERANCE_CCUSAGE_CMD="$CCUSAGE_OK"
	run sev_acquire
	[ "$status" -eq 0 ]
	jq -e '.signal_tier == "ccusage"' <<<"$output"
}

@test "tier: nothing available -> non-zero exit" {
	export SEVERANCE_OAUTH_FALLBACK=0
	export SEVERANCE_CCUSAGE_CMD="false"
	run sev_acquire
	[ "$status" -ne 0 ]
}

@test "tier: stale statusline is the last resort when tiers 2-3 fail" {
	_stale_statusline 50
	export SEVERANCE_OAUTH_FALLBACK=0
	export SEVERANCE_CCUSAGE_CMD="false"
	run sev_acquire
	[ "$status" -eq 0 ]
	jq -e '.signal_tier == "statusline" and .normalized.session.utilization == 50' <<<"$output"
}
