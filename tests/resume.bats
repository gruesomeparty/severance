#!/usr/bin/env bats
# Tests for resume.sh + schedule-resume.sh (PRD §5.5/§5.6; AC3, AC12).

load 'helpers/common'

setup() {
	sev_setup_tmp
	RESUME="$SEV_SCRIPTS/resume.sh"
	SCHEDULE="$SEV_SCRIPTS/schedule-resume.sh"
	export SEVERANCE_OAUTH_FALLBACK=0
	export SEVERANCE_CCUSAGE_CMD=false
	export SEVERANCE_RESUME_STAGGER_SECONDS=1
	SOCK="$SEV_TMP/tmux.sock"
	export SEVERANCE_TMUX="tmux -S $SOCK"
	tmux -S "$SOCK" new-session -d -s s -x 80 -y 24
	PANE="$(tmux -S "$SOCK" list-panes -a -F '#{pane_id}' | head -1)"
	PROJ="$SEVERANCE_STATE_DIR/projects"
	mkdir -p "$PROJ"
}

teardown() {
	tmux -S "$SOCK" kill-server 2>/dev/null || true
	sev_teardown_tmp
}

_usage_util() {
	jq -n --argjson u "$1" --argjson ts "$(date +%s)" '
    {ts:$ts, signal_tier:"statusline", rate_limits:null,
     normalized:{session:{utilization:$u,resets_at:null},weekly:{utilization:$u,resets_at:null},extra_usage:{is_enabled:null,used_credits:null}},
     cost:{total_cost_usd:null}, session_id:"s", model:"m", cwd:"x"}' \
		>"$SEVERANCE_STATE_DIR/usage.json"
}

_severed() { # <slug> <priority> <pane> [session_id]
	local sid="${4:-s}"
	mkdir -p "$PROJ/$1"
	jq -n --arg n "$1" --arg p "$2" --arg pane "$3" --arg sid "$sid" \
		'{name:$n, cwd:("/x/"+$n), status:"severed", reason:"session_util", priority:$p, paused:false, tmux_pane:$pane, session_id:$sid, resume_at:"2020-01-01T00:00:00Z", resume_count:0}' \
		>"$PROJ/$1/$sid.json"
}

@test "AC3: severed project past resume_at with a live pane gets the continuation prompt" {
	_usage_util 10
	_severed p normal "$PANE"
	run "$RESUME" "$PROJ/p/s.json"
	[ "$status" -eq 0 ]
	sleep 0.4
	run tmux -S "$SOCK" capture-pane -p -t "$PANE"
	[[ "$output" == *"Window has reset"* ]]
	jq -e '.status=="active" and .resume_count==1 and .resume_at==null' "$PROJ/p/s.json"
}

@test "resume: a vanished pane marks the project orphaned and does not respawn" {
	_usage_util 10
	_severed p normal "%999"
	run "$RESUME" "$PROJ/p/s.json"
	[ "$status" -eq 0 ]
	jq -e '.status=="orphaned"' "$PROJ/p/s.json"
}

@test "resume: still over threshold reschedules and does not resume" {
	_usage_util 90
	_severed p normal "$PANE"
	run "$RESUME" "$PROJ/p/s.json"
	[ "$status" -eq 0 ]
	jq -e '.status=="severed"' "$PROJ/p/s.json"
	run tmux -S "$SOCK" capture-pane -p -t "$PANE"
	[[ "$output" != *"Window has reset"* ]]
}

@test "AC12: --all resumes high before low; the between-band re-check holds low when hot" {
	_usage_util 60 # high thr 85 -> resume high; low thr 50 -> 60>=50 hold low
	PANE2="$(tmux -S "$SOCK" split-window -d -P -F '#{pane_id}' -t "$PANE")"
	_severed hi high "$PANE"
	_severed lo low "$PANE2"
	run "$RESUME" --all
	[ "$status" -eq 0 ]
	[[ "$output" == *"resumed hi"* ]]
	[[ "$output" == *"held lo"* ]]
	jq -e '.status=="active"' "$PROJ/hi/s.json"
	jq -e '.status=="severed"' "$PROJ/lo/s.json"
}

@test "AC12: --all with a cool window resumes high first, then low after the stagger" {
	_usage_util 10
	PANE2="$(tmux -S "$SOCK" split-window -d -P -F '#{pane_id}' -t "$PANE")"
	_severed hi high "$PANE"
	_severed lo low "$PANE2"
	run "$RESUME" --all
	[ "$status" -eq 0 ]
	hi_line="$(printf '%s\n' "$output" | grep -n 'resumed hi' | head -1 | cut -d: -f1)"
	lo_line="$(printf '%s\n' "$output" | grep -n 'resumed lo' | head -1 | cut -d: -f1)"
	[ -n "$hi_line" ] && [ -n "$lo_line" ] && [ "$hi_line" -lt "$lo_line" ]
	jq -e '.status=="active"' "$PROJ/hi/s.json"
	jq -e '.status=="active"' "$PROJ/lo/s.json"
}

@test "schedule-resume: invokes the scheduler with resume_at, unit, and state file" {
	export SCHED_OUT="$SEV_TMP/sched.out"
	cat >"$SEV_TMP/sched" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$SCHED_OUT"
SH
	chmod +x "$SEV_TMP/sched"
	export SEVERANCE_SCHEDULER="$SEV_TMP/sched"
	mkdir -p "$PROJ/p"
	jq -n '{name:"p", cwd:"/x", status:"severed", priority:"normal", paused:false, session_id:"sessA", resume_at:"2026-07-02T18:00:00Z"}' >"$PROJ/p/sessA.json"
	run "$SCHEDULE" "$PROJ/p/sessA.json"
	[ "$status" -eq 0 ]
	grep -q "2026-07-02T18:00:00Z" "$SCHED_OUT"
	# Unit name incorporates the session id (#15) so concurrent sessions don't collide.
	grep -q "severance-resume-p-sessA" "$SCHED_OUT"
	grep -q "sessA.json" "$SCHED_OUT"
}

@test "#15: two sessions of one slug schedule distinct systemd units" {
	export SCHED_OUT="$SEV_TMP/sched.out"
	cat >"$SEV_TMP/sched" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$2" >>"$SCHED_OUT"
SH
	chmod +x "$SEV_TMP/sched"
	export SEVERANCE_SCHEDULER="$SEV_TMP/sched"
	mkdir -p "$PROJ/p"
	jq -n '{name:"p", cwd:"/x", status:"severed", priority:"normal", paused:false, session_id:"sessA", resume_at:"2026-07-02T18:00:00Z"}' >"$PROJ/p/sessA.json"
	jq -n '{name:"p", cwd:"/x", status:"severed", priority:"normal", paused:false, session_id:"sessB", resume_at:"2026-07-02T18:00:00Z"}' >"$PROJ/p/sessB.json"
	run "$SCHEDULE" "$PROJ/p/sessA.json"
	[ "$status" -eq 0 ]
	run "$SCHEDULE" "$PROJ/p/sessB.json"
	[ "$status" -eq 0 ]
	grep -qx "severance-resume-p-sessA" "$SCHED_OUT"
	grep -qx "severance-resume-p-sessB" "$SCHED_OUT"
}

@test "schedule-resume: no resume_at is a no-op (scheduler not invoked)" {
	export SCHED_OUT="$SEV_TMP/sched.out"
	printf '#!/usr/bin/env bash\nprintf "%%s" x >"$SCHED_OUT"\n' >"$SEV_TMP/sched"
	chmod +x "$SEV_TMP/sched"
	export SEVERANCE_SCHEDULER="$SEV_TMP/sched"
	jq -n '{name:"p", cwd:"/x", status:"severed", priority:"normal", paused:false}' >"$PROJ/p.json"
	run "$SCHEDULE" "$PROJ/p.json"
	[ "$status" -eq 0 ]
	[ ! -f "$SCHED_OUT" ]
}
