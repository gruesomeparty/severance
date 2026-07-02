#!/usr/bin/env bash
# oauth-usage.sh — Severance Tier-2 signal (PRD §3).
#
# Fetches the undocumented OAuth usage endpoint and prints the raw usage JSON on
# stdout (exit 0). On ANY failure — missing token, non-200, timeout, unparseable
# body — it exits non-zero and prints nothing, so the caller falls through to
# Tier-3 silently. Responses are cached for 60s (shared, under a lock) to honor
# the "min 60s between requests" rule. The access token is used only in memory
# and in the request header; it is NEVER logged or persisted.
#
# Test hooks: SEVERANCE_OAUTH_URL (endpoint), SEVERANCE_CREDENTIALS_FILE (token
# source, bypassing the Keychain), SEVERANCE_OAUTH_TIMEOUT (curl -m seconds).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugin/scripts/severance-lib.sh disable=SC1091
source "$SCRIPT_DIR/severance-lib.sh"

OAUTH_URL="${SEVERANCE_OAUTH_URL:-https://api.anthropic.com/api/oauth/usage}"
OAUTH_TIMEOUT="${SEVERANCE_OAUTH_TIMEOUT:-10}"
CACHE_TTL=60

state_dir="$(sev_state_dir)"
mkdir -p "$state_dir"
cache="$state_dir/oauth-cache.json"
lock="$state_dir/oauth.lock"

# _oauth_token — print the OAuth access token, or fail (non-zero) if unavailable.
_oauth_token() {
	local creds="" tok
	if [ -n "${SEVERANCE_CREDENTIALS_FILE:-}" ]; then
		[ -f "$SEVERANCE_CREDENTIALS_FILE" ] || return 1
		creds="$(cat "$SEVERANCE_CREDENTIALS_FILE")" || return 1
	elif [ "$(uname -s)" = "Darwin" ]; then
		creds="$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null)" || return 1
	else
		[ -f "$HOME/.claude/.credentials.json" ] || return 1
		creds="$(cat "$HOME/.claude/.credentials.json")" || return 1
	fi
	tok="$(printf '%s' "$creds" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)" || return 1
	[ -n "$tok" ] || return 1
	printf '%s' "$tok"
}

# _oauth_fetch — GET the endpoint; print the raw body on 200+valid-JSON, else fail.
_oauth_fetch() {
	local token resp http body
	token="$(_oauth_token)" || return 1
	resp="$(curl -sS -m "$OAUTH_TIMEOUT" \
		-H "Authorization: Bearer $token" \
		-H "anthropic-beta: oauth-2025-04-20" \
		-H "Content-Type: application/json" \
		-w $'\n%{http_code}' \
		"$OAUTH_URL" 2>/dev/null)" || return 1
	http="${resp##*$'\n'}"
	body="${resp%$'\n'*}"
	[ "$http" = "200" ] || return 1
	printf '%s' "$body" | jq -e . >/dev/null 2>&1 || return 1
	printf '%s' "$body"
}

# Fast path: serve a fresh (<60s) cached response without touching the network.
if [ -f "$cache" ]; then
	cts="$(jq -r '.ts // 0' "$cache" 2>/dev/null || echo 0)"
	now="$(sev_now)"
	age=$((now - cts))
	if [ "$age" -ge 0 ] && [ "$age" -lt "$CACHE_TTL" ]; then
		jq -c '.response' "$cache"
		exit 0
	fi
fi

# Slow path: fetch, cache, print. Any failure -> silent non-zero (fall through).
if body="$(_oauth_fetch)"; then
	jq -n --argjson resp "$body" --argjson ts "$(sev_now)" '{ts: $ts, response: $resp}' |
		sev_locked "$lock" sev_atomic_write "$cache" || true
	printf '%s' "$body"
	exit 0
fi
exit 1
