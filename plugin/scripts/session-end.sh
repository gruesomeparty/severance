#!/usr/bin/env bash
# session-end.sh — Severance SessionEnd hook (issue #15).
#
# Project state is partitioned per session (projects/<slug>/<session_id>.json).
# Without cleanup, every session ever run would leave a file behind. On SessionEnd
# this removes THIS session's record and prunes the now-empty <slug>/ directory.
# It is a side-effect-only hook (SessionEnd has no decision control) and must never
# error the session: every step is best-effort and resilient to an absent file.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugin/scripts/severance-lib.sh disable=SC1091
source "$SCRIPT_DIR/severance-lib.sh"

input="$(cat)"
# Installed but not enabled here is a provable no-op (matches gate/heartbeat).
[ "$(sev_config_get SEVERANCE_ENABLED 0)" = "1" ] || exit 0

cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -n "$cwd" ] || cwd="$PWD"
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
# No session id -> nothing to key a per-session file on; leave state untouched.
[ -n "$session_id" ] || exit 0

slug="$(sev_slug "$cwd")"
sf="$(sev_project_state_file "$slug" "$session_id")"

# Remove this session's record; also drop its lock sidecars if present.
rm -f "$sf" "$sf.lock" 2>/dev/null || true
rmdir "$sf.lock.d" 2>/dev/null || true
# Prune the <slug>/ directory when this was its last session (best-effort).
rmdir "$(dirname "$sf")" 2>/dev/null || true

exit 0
