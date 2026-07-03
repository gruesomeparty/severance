#!/usr/bin/env bash
# schedule-resume.sh — schedule an auto-resume at the window reset (PRD §5.5).
#
# Linux: a transient systemd --user timer fires resume.sh at resume_at. macOS: a
# no-op — the menu bar app owns scheduling by watching the state files. Tests set
# SEVERANCE_SCHEDULER to a stub that receives <resume_at> <unit> <state-file>.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugin/scripts/severance-lib.sh disable=SC1091
source "$SCRIPT_DIR/severance-lib.sh"

sf="${1:-}"
[ -n "$sf" ] && [ -f "$sf" ] || exit 0

resume_at="$(jq -r '.resume_at // empty' "$sf" 2>/dev/null || true)"
slug="$(jq -r '.name // empty' "$sf" 2>/dev/null || true)"
[ -n "$resume_at" ] && [ -n "$slug" ] || exit 0
unit="severance-resume-$slug"

scheduler="${SEVERANCE_SCHEDULER:-}"
if [ -z "$scheduler" ]; then
	# Default backend: systemd --user on Linux; elsewhere the app schedules.
	[ "$(uname -s)" = "Linux" ] || exit 0
	command -v systemd-run >/dev/null 2>&1 || exit 0
	systemd-run --user --on-calendar="$resume_at" --unit="$unit" --collect \
		"$SEV_SELF_DIR/resume.sh" "$sf" >/dev/null 2>&1 || true
	exit 0
fi

# Custom/test scheduler.
"$scheduler" "$resume_at" "$unit" "$sf" || true
exit 0
