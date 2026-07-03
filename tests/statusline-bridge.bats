#!/usr/bin/env bats
# Tests for statusline-bridge.sh (PRD §5.3, §9.4): persist Tier-1 signal to
# usage.json atomically, then delegate stdin unchanged to the inner statusline.

load 'helpers/common'

setup() {
	sev_setup_tmp
	BRIDGE="$SEV_SCRIPTS/statusline-bridge.sh"
}

teardown() {
	sev_teardown_tmp
}

@test "bridge writes usage.json: statusline tier, normalized, verbatim rate_limits, extracted fields" {
	"$BRIDGE" <"$SEV_FIXTURES/signal/statusline-stdin.json" >/dev/null
	f="$SEVERANCE_STATE_DIR/usage.json"
	[ -f "$f" ]
	jq -e '
    .signal_tier == "statusline"
    and .normalized.session.utilization == 23.5
    and .rate_limits.five_hour.used_percentage == 23.5
    and .cost.total_cost_usd == 1.42
    and .session_id == "sess-abc123"
    and .model == "claude-sonnet-5"
    and .cwd == "/home/berkay/dev/one-ocean-cms"
    and (.ts | type == "number")
  ' "$f"
}

@test "bridge usage.json validates against usage-cache schema" {
	"$BRIDGE" <"$SEV_FIXTURES/signal/statusline-stdin.json" >/dev/null
	run check-jsonschema --schemafile "$SEV_ROOT/schemas/usage-cache.schema.json" "$SEVERANCE_STATE_DIR/usage.json"
	[ "$status" -eq 0 ]
}

@test "bridge handles missing rate_limits (older CC): cost recorded, windows null" {
	"$BRIDGE" <"$SEV_FIXTURES/signal/statusline-stdin-no-ratelimits.json" >/dev/null
	f="$SEVERANCE_STATE_DIR/usage.json"
	jq -e '.rate_limits == null and .normalized.session.utilization == null and .cost.total_cost_usd == 0.05' "$f"
}

@test "bridge delegates identical stdin to the inner statusline" {
	export SEVERANCE_INNER_STATUSLINE="cat > '$SEV_TMP/inner.json'"
	"$BRIDGE" <"$SEV_FIXTURES/signal/statusline-stdin.json" >/dev/null
	run bash -c 'diff <(jq -S . "$1") <(jq -S . "$2")' _ "$SEV_TMP/inner.json" "$SEV_FIXTURES/signal/statusline-stdin.json"
	[ "$status" -eq 0 ]
}

@test "bridge default line (no inner) prints a compact 5h reading" {
	run "$BRIDGE" <"$SEV_FIXTURES/signal/statusline-stdin.json"
	[ "$status" -eq 0 ]
	[[ "$output" == *"5h 23%"* ]]
}

@test "bridge never blanks the statusline when persistence dir is unwritable" {
	export SEVERANCE_STATE_DIR="/proc/nonexistent-cannot-write/sev"
	run "$BRIDGE" <"$SEV_FIXTURES/signal/statusline-stdin.json"
	[ "$status" -eq 0 ]
	[[ "$output" == *"5h"* ]]
}

@test "bridge writes a per-session cost file (so the cost cap is per-session)" {
	"$BRIDGE" <"$SEV_FIXTURES/signal/statusline-stdin.json" >/dev/null
	f="$SEVERANCE_STATE_DIR/sessions/sess-abc123.json"
	[ -f "$f" ]
	jq -e '.session_id == "sess-abc123" and .cost.total_cost_usd == 1.42' "$f"
	run check-jsonschema --schemafile "$SEV_ROOT/schemas/session-cost.schema.json" "$f"
	[ "$status" -eq 0 ]
}

@test "bridge concurrent invocations keep usage.json valid JSON" {
	for _ in $(seq 1 15); do
		"$BRIDGE" <"$SEV_FIXTURES/signal/statusline-stdin.json" >/dev/null &
	done
	wait
	run jq -e . "$SEVERANCE_STATE_DIR/usage.json"
	[ "$status" -eq 0 ]
}
