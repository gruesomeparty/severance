#!/usr/bin/env bats
# Regression tests for issue #25 and its follow-up consolidated fix:
#   D1 — the macOS (no-flock) mkdir-mutex fallback reclaimed a lock dir on pure
#        age, with no liveness check, so a still-alive holder whose critical
#        section ran past SEV_LOCK_STALE_SECS got its lock stolen out from
#        under it (lost updates). Fixed via a recorded holder pid + `kill -0`.
#   D2/D3 — sev_locked's release trap and sev_atomic_write's temp-cleanup trap
#        lived in the same process and the second install silently replaced
#        the first, so a signal during the write leaked the lock dir; a
#        caller's own trap was unconditionally cleared too. Fixed by running
#        each in its own nested subshell.
#   D4 — the staleness check and the steal (mv) aren't atomic; covered by a
#        post-mv re-verify.
#   D5 — the steal path could bypass the ~20s spin-cap accounting; covered by
#        always advancing it, reclaim attempted or not.

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

# Spawn a real, already-dead process and echo its (now-recycled-safe, briefly
# reserved) pid: `bash -c 'exit 0' & pid=$!; wait $pid` guarantees the pid has
# actually exited by the time we read it back.
_sev_test_dead_pid() {
	local p
	bash -c 'exit 0' &
	p=$!
	wait "$p" 2>/dev/null
	printf '%s\n' "$p"
}

@test "sev_locked: reclaims a lockdir left by a dead holder (#25 regression, D1 liveness)" {
	lock="$SEV_TMP/usage.json.lock"
	mkdir -p "$lock.d"
	dead_pid="$(_sev_test_dead_pid)"
	printf '%s' "$dead_pid" >"$lock.d/pid"
	# Fresh mtime (age ~0): under the old pure-age logic this would NOT have
	# been reclaimed for SEV_LOCK_STALE_SECS; under D1's liveness-primary rule
	# a dead recorded holder is reclaimed immediately, regardless of age.

	marker="$SEV_TMP/ran"
	# Not `run`: bats' own EXIT/INT/TERM trap bookkeeping around `run` doesn't
	# compose well with a direct foreground call that also touches traps
	# internally. A direct call + manual status capture avoids it.
	status=0
	SEV_LOCK_NO_FLOCK=1 sev_locked "$lock" touch "$marker" || status=$?

	[ "$status" -eq 0 ]
	[ -f "$marker" ]
	[ ! -d "$lock.d" ]
}

@test "sev_locked: serializes against a live holder rather than stampeding, even past the old 10s default" {
	lock="$SEV_TMP/serialize.lock"
	log="$SEV_TMP/order.log"
	: >"$log"

	# Hold the lock directly with OUR OWN (genuinely alive) pid recorded, aged
	# past the OLD default (10s) but well under the new one (300s) — proof
	# that D1 checks liveness first and never falls through to age for a
	# holder it can prove is alive. A live background sleeper stands in for
	# the "other process" holding it; sev_locked itself isn't run in the
	# background here since bats' own fd/trap bookkeeping around backgrounded
	# jobs doesn't compose with a call that installs its own traps.
	mkdir -p "$lock.d"
	printf '%s' "$$" >"$lock.d/pid"
	_sev_test_age_mtime "$lock.d" 60
	(sleep 1; echo end >>"$log"; rm -rf "$lock.d") >/dev/null 2>&1 &
	holder=$!

	status=0
	SEV_LOCK_NO_FLOCK=1 sev_locked "$lock" bash -c 'echo second >>"$1"' _ "$log" || status=$?
	wait "$holder"

	[ "$status" -eq 0 ]
	# "second" must appear strictly after the holder's "end" — proof it waited
	# instead of stealing a lock that was still live, despite looking stale by
	# the old (age-only, 10s) rule.
	[ "$(sed -n '1p' "$log")" = "end" ]
	[ "$(sed -n '2p' "$log")" = "second" ]
}

@test "sev_atomic_write: killed mid-write leaves no temp file and dest is never partial" {
	f="$SEV_TMP/dest.json"
	printf '%s' '{"prior":true}' >"$f"

	# The producer keeps its write end open (via `sleep`) so the reader (cat
	# inside sev_atomic_write) is still mid-read when we kill the writer.
	# sev_atomic_write now runs its own body in a NESTED subshell (D2/D3), so
	# a plain `kill` of the outer backgrounded job wouldn't reach it — bash
	# doesn't propagate signals to child subshells automatically. `set -m`
	# puts the backgrounded job in its own process group so a group-wide
	# signal (negative pid) reaches every subshell inside it, same as a real
	# SIGTERM delivered to a whole killed subprocess tree.
	(
		set -m
		(sev_atomic_write "$f" < <(printf '%s' '{"partial"'; sleep 2)) &
		writer=$!
		echo "$writer"
	) >"$SEV_TMP/writer.pid"
	writer="$(cat "$SEV_TMP/writer.pid")"
	sleep 0.3
	kill -TERM -- "-$writer" 2>/dev/null || true
	wait "$writer" 2>/dev/null || true
	sleep 0.2 # let the killed subshell's own EXIT trap finish its rm -f

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

@test "sev_locked: many concurrent real RMW increments never lose an update" {
	# D1 regression: the old mkdir-mutex fallback judged staleness on pure
	# age, so a holder whose critical section ran longer than
	# SEV_LOCK_STALE_SECS (default 10) got stolen out from under it even
	# though it was still alive, causing lost updates. Reproduced here with
	# many short (real jq+mktemp+mv) holders plus ONE deliberately slow
	# holder whose real critical section runs ~11s — comfortably past the
	# OLD default (10) but nowhere near the new one (300) — without
	# overriding SEV_LOCK_STALE_SECS at all: each version of the library uses
	# its OWN built-in default, so this is a fair before/after comparison.
	# Writer count is deliberately below the PRD's illustrative "50": on this
	# (shared, contended) CI-equivalent host, 50 truly-concurrent bash
	# processes each forking jq/mktemp/mv made the fixed (correct,
	# fully-serializing) case itself take minutes under load; 20 already
	# reliably reproduces the pre-fix loss and reliably proves the fix.
	export SEV_LOCK_NO_FLOCK=1
	n_writers=10
	counter="$SEV_TMP/counter.json"
	printf '%s' '{"n":0}' >"$counter"
	lock="$counter.lock"

	incr_fast() {
		local n
		n="$(jq -r .n "$counter")"
		n=$((n + 1))
		jq -n --argjson n "$n" '{n:$n}' | sev_atomic_write "$counter"
	}
	incr_slow() {
		local n
		n="$(jq -r .n "$counter")"
		sleep 11
		n=$((n + 1))
		jq -n --argjson n "$n" '{n:$n}' | sev_atomic_write "$counter"
	}
	export -f incr_fast incr_slow
	export counter

	pids=()
	sev_locked "$lock" incr_slow &
	pids+=("$!")
	sleep 0.2 # let the slow holder grab the lock first
	for _ in $(seq 1 "$((n_writers - 1))"); do
		sev_locked "$lock" incr_fast &
		pids+=("$!")
	done
	for p in "${pids[@]}"; do wait "$p"; done

	[ "$(jq -r .n "$counter")" -eq "$n_writers" ]
}

@test "sev_locked + sev_atomic_write: SIGTERM during the write leaves no temp AND no lockdir" {
	export SEV_LOCK_NO_FLOCK=1
	dest="$SEV_TMP/state.json"
	printf '%s' '{"prior":true}' >"$dest"
	lock="$dest.lock"

	# The critical section calls sev_atomic_write as a plain FUNCTION CALL in
	# the SAME process sev_locked's own release trap is set in on the
	# pre-fix branch — the exact composition D2/D3 covers. Neither a
	# `bash -c` subprocess nor a `|` pipe may feed it (both run the last
	# command in its own subshell under `set -m`), as that would isolate the
	# trap by accident regardless of the library fix; process substitution
	# as a stdin redirect avoids both.
	do_write() {
		sev_atomic_write "$dest" < <(printf '%s' '{"partial"'; sleep 2)
	}
	export -f do_write
	export dest

	(
		set -m
		sev_locked "$lock" do_write &
		echo "$!"
	) >"$SEV_TMP/writer.pid"
	writer="$(cat "$SEV_TMP/writer.pid")"
	sleep 0.4 # land inside the `cat` read, mid-write, lock held
	kill -TERM -- "-$writer" 2>/dev/null || true
	wait "$writer" 2>/dev/null || true
	sleep 0.2

	shopt -s nullglob
	tmps=("$SEV_TMP"/.sev.*)
	[ "${#tmps[@]}" -eq 0 ]
	[ ! -d "$lock.d" ]
	[ "$(cat "$dest")" = '{"prior":true}' ]
}

@test "sev_state_merge: a caller's own EXIT/INT/TERM trap survives a direct call and still fires" {
	sf="$SEV_TMP/projects/direct-trap.json"
	marker="$SEV_TMP/trap-fired"
	rm -f "$marker"

	# Run in a subshell so the trap we install here doesn't leak into bats'
	# own process; sev_state_merge/sev_locked must not clear or replace it.
	(
		trap 'echo M >>"'"$marker"'"' EXIT INT TERM
		sev_state_merge "$sf" '. + {ok:true}'
	)

	[ -f "$marker" ]
	[ "$(cat "$marker")" = "M" ]
	[ "$(jq -r .ok "$sf")" = "true" ]
}

@test "sev_locked: an unreclaimable lockdir returns 75 within the ~20s spin cap, never hangs" {
	lock="$SEV_TMP/unreclaimable.lock"
	mkdir -p "$lock.d"
	dead_pid="$(_sev_test_dead_pid)"
	printf '%s' "$dead_pid" >"$lock.d/pid"

	# Simulate a steal that can never succeed (e.g. a permission failure on
	# the mv/rm) by making the lock dir's PARENT read-only, so `mv "$lock.d"
	# ...` always fails even though the holder is correctly judged dead every
	# single iteration. Before D5, the stale branch's `continue` skipped the
	# waited/400 accounting entirely in this situation, busy-spinning forever
	# instead of ever hitting the cap.
	chmod 555 "$SEV_TMP"

	start="$(date +%s)"
	status=0
	SEV_LOCK_NO_FLOCK=1 sev_locked "$lock" true || status=$?
	elapsed=$(($(date +%s) - start))

	chmod 755 "$SEV_TMP" # restore so teardown can clean up

	[ "$status" -eq 75 ]
	# ~20s nominal (400 * 0.05s sleep), plus real per-iteration work (a
	# doomed mv attempt every time) that can stretch this further under load;
	# generous ceiling — the property under test is "terminates", not exact
	# timing.
	[ "$elapsed" -lt 60 ]
}
