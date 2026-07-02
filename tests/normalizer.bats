#!/usr/bin/env bats
# Tests for sev_normalize — the D3 probe list that maps any tier's raw signal to
# the normalized {session, weekly, extra_usage} block consumers read.

load 'helpers/common'

setup() {
	sev_setup_tmp
	source "$SEV_LIB"
}

teardown() {
	sev_teardown_tmp
}

@test "normalize statusline: used_percentage + epoch resets_at -> ISO" {
	out="$(sev_normalize <"$SEV_FIXTURES/signal/statusline-stdin.json")"
	jq -e '
    .session.utilization == 23.5
    and (.session.resets_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and .weekly.utilization == 41.2
    and (.weekly.resets_at | test("Z$"))
    and .extra_usage.is_enabled == null
    and .extra_usage.used_credits == null
  ' <<<"$out"
}

@test "normalize statusline without rate_limits: windows null" {
	out="$(sev_normalize <"$SEV_FIXTURES/signal/statusline-stdin-no-ratelimits.json")"
	jq -e '
    .session.utilization == null and .session.resets_at == null
    and .weekly.utilization == null and .weekly.resets_at == null
  ' <<<"$out"
}

@test "normalize statusline: zero utilization is preserved (not null)" {
	out="$(sev_normalize <"$SEV_FIXTURES/signal/statusline-stdin-zero.json")"
	jq -e '.session.utilization == 0 and .weekly.utilization == 0' <<<"$out"
}

@test "normalize oauth: utilization + ISO resets_at pass through; extra_usage read" {
	out="$(sev_normalize <"$SEV_FIXTURES/signal/oauth-response.json")"
	jq -e '
    .session.utilization == 37.0
    and .session.resets_at == "2026-02-08T04:59:59+00:00"
    and .weekly.utilization == 26.0
    and .extra_usage.is_enabled == false
    and .extra_usage.used_credits == null
  ' <<<"$out"
}

@test "normalize oauth: used_credits > 0 surfaced" {
	out="$(sev_normalize <"$SEV_FIXTURES/signal/oauth-response-extra-usage.json")"
	jq -e '.extra_usage.is_enabled == true and .extra_usage.used_credits == 12.5' <<<"$out"
}

@test "normalized output validates against the usage-cache window shape" {
	# The normalized block must slot into a full usage.json that passes the schema.
	norm="$(sev_normalize <"$SEV_FIXTURES/signal/statusline-stdin.json")"
	usage="$(jq -n --argjson n "$norm" '{ts:1751450000, signal_tier:"statusline", normalized:$n}')"
	echo "$usage" >"$SEV_TMP/usage.json"
	run check-jsonschema --schemafile "$SEV_ROOT/schemas/usage-cache.schema.json" "$SEV_TMP/usage.json"
	[ "$status" -eq 0 ]
}

@test "sev_now returns epoch seconds" {
	run sev_now
	[ "$status" -eq 0 ]
	[[ "$output" =~ ^[0-9]+$ ]]
	[ "$output" -gt 1700000000 ]
}
