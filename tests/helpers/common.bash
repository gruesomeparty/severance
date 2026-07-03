#!/usr/bin/env bash
# Shared helpers for Severance bats tests. Loaded via `load 'helpers/common'`.

# Repo root, derived from the running .bats file's directory (tests/).
SEV_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
export SEV_ROOT
export SEV_SCRIPTS="$SEV_ROOT/plugin/scripts"
export SEV_FIXTURES="$SEV_ROOT/tests/fixtures"
export SEV_LIB="$SEV_SCRIPTS/severance-lib.sh"

# Fresh isolated state dir per test; callers `source "$SEV_LIB"` after this.
sev_setup_tmp() {
	# Hermetic: clear any ambient SEVERANCE_* config (e.g. a project's
	# .claude/settings.json env that Claude Code exports into this shell) so tests
	# depend only on what they set themselves.
	unset SEVERANCE_ENABLED SEVERANCE_PRIORITY SEVERANCE_UTIL_PCT SEVERANCE_WEEKLY_PCT \
		SEVERANCE_LIMIT_USD SEVERANCE_ALLOW_EXTRA_USAGE SEVERANCE_MAX_RESUMES \
		SEVERANCE_OAUTH_FALLBACK SEVERANCE_CCUSAGE_CMD SEVERANCE_INNER_STATUSLINE \
		SEVERANCE_OAUTH_URL SEVERANCE_CREDENTIALS_FILE SEVERANCE_OAUTH_TIMEOUT \
		SEVERANCE_RESUME_STAGGER_SECONDS SEVERANCE_TMUX SEVERANCE_SCHEDULER \
		SEVERANCE_TIER1_MAX_AGE 2>/dev/null || true

	SEV_TMP="$(mktemp -d "${BATS_TMPDIR:-/tmp}/sev.XXXXXX")"
	export SEV_TMP
	export SEVERANCE_STATE_DIR="$SEV_TMP/state"
	mkdir -p "$SEVERANCE_STATE_DIR/projects"
}

sev_teardown_tmp() {
	[ -n "${SEV_TMP:-}" ] && rm -rf "$SEV_TMP"
}
