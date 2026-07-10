#!/usr/bin/env bats
# Regression tests for issue #25: the macOS (no-flock) mkdir-mutex fallback of
# sev_locked() leaked its lock dir forever when the holder died mid-critical-
# section, and sev_atomic_write() leaked its mktemp temp the same way. Covers
# age-based stale-lock reclaim, live-holder serialization, atomic-write temp
# cleanup on death, and that the flock branch (Linux) is untouched.

load 'helpers/common'

setup() {
	sev_setup_tmp
	source "$SEV_LIB"
}

teardown() {
	sev_teardown_tmp
}

# Portable: back-date a path's mtime by N seconds (BSD `touch -t` vs GNU `date -d`
# for computing the timestamp string; the `-t` flag itself is POSIX-common).
_sev_test_age_mtime() {
	local target="$1" secs_ago="$2" epoch stamp
	epoch=$(($(date +%s) - secs_ago))
	stamp="$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$epoch" +%Y%m%d%H%M.%S)"
	touch -t "$stamp" "$target"
}

@test "sev_locked: reclaims a stale lockdir left by a dead holder (#25 regression)" {
	lock="$SEV_TMP/usage.json.lock"
	mkdir -p "$lock.d"
	_sev_test_age_mtime "$lock.d" 60

	marker="$SEV_TMP/ran"
	# Not `run`: sev_locked's mkdir-fallback saves/restores the process's
	# EXIT/INT/TERM traps (#25 release safety), which fights bats' own use of
	# those traps inside `run`. A direct call + manual status capture avoids it.
	status=0
	SEV_LOCK_NO_FLOCK=1 sev_locked "$lock" touch "$marker" || status=$?

	[ "$status" -eq 0 ]
	[ -f "$marker" ]
	[ ! -d "$lock.d" ]
}

@test "sev_locked: serializes against a live holder rather than stampeding" {
	lock="$SEV_TMP/serialize.lock"
	log="$SEV_TMP/order.log"
	: >"$log"

	# Hold the lock directly (fresh mtime, well under the stale threshold) with
	# a live background sleeper standing in for another process — sev_locked
	# itself isn't run in the background here since bats' own fd/trap-based
	# bookkeeping around backgrounded jobs doesn't compose with the trap
	# save/restore dance sev_locked's mkdir-fallback does (#25 release safety).
	mkdir -p "$lock.d"
	(sleep 1; echo end >>"$log"; rmdir "$lock.d") >/dev/null 2>&1 &
	holder=$!

	status=0
	SEV_LOCK_NO_FLOCK=1 sev_locked "$lock" bash -c 'echo second >>"$1"' _ "$log" || status=$?
	wait "$holder"

	[ "$status" -eq 0 ]
	# "second" must appear strictly after the holder's "end" — proof it waited
	# instead of stealing a lock that was still live (age < stale threshold).
	[ "$(sed -n '1p' "$log")" = "end" ]
	[ "$(sed -n '2p' "$log")" = "second" ]
}

@test "sev_atomic_write: killed mid-write leaves no temp file and dest is never partial" {
	f="$SEV_TMP/dest.json"
	printf '%s' '{"prior":true}' >"$f"

	# The producer keeps its write end open (via `sleep`) so the reader (cat
	# inside sev_atomic_write) is still mid-read when we kill the writer.
	(sev_atomic_write "$f" < <(printf '%s' '{"partial"'; sleep 2)) &
	writer=$!
	sleep 0.3
	kill -TERM "$writer" 2>/dev/null || true
	wait "$writer" 2>/dev/null || true

	shopt -s nullglob
	tmps=("$SEV_TMP"/.sev.*)
	[ "${#tmps[@]}" -eq 0 ]
	[ "$(cat "$f")" = '{"prior":true}' ]
}

@test "sev_locked: flock path is used unchanged when flock is present" {
	if ! command -v flock >/dev/null 2>&1; then
		skip "flock not installed on this host"
	fi
	lock="$SEV_TMP/flock-path.lock"
	run sev_locked "$lock" true
	[ "$status" -eq 0 ]
	run sev_locked "$lock" false
	[ "$status" -ne 0 ]
	# the flock branch never creates the mkdir-mutex artifact
	[ ! -d "$lock.d" ]
}
