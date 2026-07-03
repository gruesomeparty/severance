# Installing Severance

Two pieces: the **plugin** (gate + auto-resume, Linux & macOS) and the **menu
bar app** (macOS dashboard + resume scheduler). Install the plugin first.

## Prerequisites

- Claude Code (recent enough to emit `rate_limits` on the statusline — Pro/Max
  login for Tier-1; older versions degrade to the OAuth/`ccusage` fallbacks).
- `bash`, `jq`, `tmux` (auto-resume drives your original tmux pane).
- Interactive sessions **under tmux** (Non-Goal: no headless `claude -p`).

## 1. Install the plugin

```
/plugin marketplace add gruesomeparty/severance
/plugin install severance@severance
```

Installing it is a **no-op** until a project opts in — it never touches your work
repos.

> The live repository is currently `suTerminus/severance` while the account is
> renamed to `gruesomeparty`; until then use `/plugin marketplace add
> suTerminus/severance`. See `docs/DEVIATIONS.md` (D4).

## 2. Enable a project

In the side project's `.claude/settings.json`:

```json
{ "env": { "SEVERANCE_ENABLED": "1", "SEVERANCE_PRIORITY": "normal" } }
```

Or just ask Claude: *"set up severance for this repo"* — the bundled
`configuring-severance` skill does all of this, including the statusline bridge.
Then add `.severance/` to the project's `.gitignore`.

## 3. Wire the statusline bridge (once, in `~/.claude/settings.json`)

The bridge captures Anthropic's official `rate_limits` (the best signal) and
delegates to your existing statusline. Point `statusLine.command` at the bridge
in the installed plugin, moving any current statusline command into
`SEVERANCE_INNER_STATUSLINE`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/ABSOLUTE/PATH/TO/plugin/scripts/statusline-bridge.sh"
  },
  "env": {
    "SEVERANCE_INNER_STATUSLINE": "your previous statusline command (optional)"
  }
}
```

Find the installed path with `claude plugin list` (look for `severance`, then
`.../plugin/scripts/statusline-bridge.sh`). Without the bridge, Severance still
works via the OAuth fallback and the `ccusage` estimate — just less precisely.

## 4. Verify

```
/severance:severance-status
```

Reports the live signal tier (`statusline` > `oauth` > `ccusage`) and current
utilization.

## Linux auto-resume

On Linux, sever events schedule a transient `systemd --user` timer that fires
`resume.sh` at the window reset (requires a user systemd session:
`loginctl enable-linger $USER` if resumes should run while logged out).

## macOS menu bar app

`Severance.app` provides the dashboard and owns resume scheduling on macOS.

Until it is released, build from source (Swift 5.10+, macOS 14+):

```
cd apps/menubar && swift build -c release
scripts/bundle-app.sh    # produces Severance.app
```

The app is unsigned by default. On first launch Gatekeeper will block it:
right-click → **Open**, or run `xattr -dr com.apple.quarantine Severance.app`.
The app is **not** sandboxed (it needs tmux, the Keychain, and file reads) — see
the app section of the README for the rationale.

## Uninstall

`/plugin uninstall severance`, remove the `SEVERANCE_*` env from project
settings, and delete `~/.claude/severance/` if you want to clear all state.
