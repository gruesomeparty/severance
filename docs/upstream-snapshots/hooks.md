# Snapshot: hooks (gate / heartbeat)

Source: `https://code.claude.com/docs/en/hooks.md` — captured 2026-07-03.

## Events Severance registers

`PreToolUse`, `SessionStart`, `Stop` — all confirmed present with these exact
spellings. (The event set is much larger now — `PostToolUse`, `SessionEnd`,
`SubagentStart/Stop`, `PermissionRequest`, `TaskCreated`, etc. — but Severance
only needs these three.)

## stdin payloads

### PreToolUse
```json
{
  "session_id": "abc123",
  "prompt_id": "550e8400-...",
  "transcript_path": "/…/transcript.jsonl",
  "cwd": "/home/user/my-project",
  "permission_mode": "default",
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_input": { "command": "npm test" }
}
```
For Write/Edit tools `tool_input.file_path` **is present** — so the gate can
whitelist writes under `.severance/` by parsing `.tool_input.file_path`
(PRD §5.2 edge case). Confirmed.

### SessionStart
```json
{
  "session_id": "abc123",
  "transcript_path": "/…/….jsonl",
  "cwd": "/…",
  "hook_event_name": "SessionStart",
  "source": "startup",
  "model": "claude-sonnet-5"
}
```
`source` ∈ `startup | resume | clear | compact`. (Note: SessionStart has **no
`matcher`** — matchers are for tool events.)

### Stop
```json
{
  "session_id": "abc123",
  "prompt_id": "550e8400-...",
  "transcript_path": "/…/transcript.jsonl",
  "cwd": "/home/user/my-project",
  "permission_mode": "default",
  "hook_event_name": "Stop"
}
```

## Exit-code semantics (verbatim, the rows Severance relies on)

| Exit | Meaning | Processing |
|---|---|---|
| 0 | Success | stdout parsed for JSON output fields |
| 2 | Blocking error | stdout/JSON ignored; **stderr fed to Claude** |
| other | Non-blocking error | JSON ignored; first stderr line shown in transcript |

Per-event "can block on exit 2":

| Event | Can block? | Exit-2 effect |
|---|---|---|
| `PreToolUse` | **Yes** | Blocks the tool call (stderr → model) |
| `Stop` | Yes | Prevents Claude from stopping (we never do this — heartbeat exits 0) |
| **`SessionStart`** | **No** | **stderr shown to user only — CANNOT block** |

## ⚠️ Deviation D2 — SessionStart cannot block

PRD §5.2 / §5 assume `SessionStart` exit 2 blocks a reopened severed project.
Current docs: SessionStart exit 2 only shows stderr to the user; it cannot stop
the session. See [`../DEVIATIONS.md`](../DEVIATIONS.md) (D2).

**Chosen spec-compliant behavior (M3):** the SessionStart gate
- writes the initial heartbeat / refreshes project state, and
- when still severed, emits `hookSpecificOutput.additionalContext` (JSON, exit 0)
  telling the model it is "still severed until <resets_at>";
- **enforcement remains on the `PreToolUse` gate**, which blocks the first tool
  call — so no tool actually runs while severed. Net effect matches the PRD's
  intent (nothing gets spent) even though the block point moves by one hook.

## JSON stdout control (alternative to exit 2)

PreToolUse also supports structured output — preferred by newer CC:
```json
{ "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "…" } }
```
`permissionDecision` ∈ `allow | deny | ask | defer`. Severance keeps the PRD's
**exit-2 + stderr** path for PreToolUse (documented to still work and it carries
the handover instruction directly), and uses **JSON `additionalContext`** for
SessionStart. The compat skill tracks the JSON-decision path in case exit codes
are deprecated.

SessionStart JSON output shape:
```json
{ "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "…still severed until <resets_at>…" } }
```

## Plugin hook config (`plugin/hooks/hooks.json`)

```json
{
  "description": "…",
  "hooks": {
    "PreToolUse": [
      { "matcher": "…",
        "hooks": [ { "type": "command",
                     "command": "${CLAUDE_PLUGIN_ROOT}/scripts/gate.sh",
                     "args": [], "timeout": 10 } ] }
    ]
  }
}
```
- `timeout` is in **seconds** (default 600 for `command`). Severance sets
  explicit small timeouts (gate 10s, heartbeat 5s).
- Commands reference `${CLAUDE_PLUGIN_ROOT}` — never absolute paths.
- Matcher: `"Bash"`, `"Edit|Write"`, regex like `"mcp__memory__.*"`. For
  match-all on PreToolUse, verify at M4 whether `"*"`, `".*"`, or an omitted
  matcher is the current idiom (PRD uses `*`).
