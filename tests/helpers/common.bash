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
	SEV_TMP="$(mktemp -d "${BATS_TMPDIR:-/tmp}/sev.XXXXXX")"
	export SEV_TMP
	export SEVERANCE_STATE_DIR="$SEV_TMP/state"
	mkdir -p "$SEVERANCE_STATE_DIR/projects"
}

sev_teardown_tmp() {
	[ -n "${SEV_TMP:-}" ] && rm -rf "$SEV_TMP"
}
