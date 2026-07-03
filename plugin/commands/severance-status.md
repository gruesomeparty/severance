---
description: Print the current Severance budget-gate status — signal tier, 5h/7d refinement quotas, and per-project sever/resume state. Use when the user asks about severance status, budget usage, or which projects are severed/paused.
argument-hint: ""
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/severance-status.sh)
---

Current Severance state:

!`"${CLAUDE_PLUGIN_ROOT}/scripts/severance-status.sh"`

Briefly summarize the above for the user: how close each window (5h / 7d) is to its limit, which refiners are severed or paused and when they return to the floor, and flag any usage-credit consumption. If a project is severed, remind the user they can resume it now from the menu bar app or wait for the scheduled reset. Keep it short.
