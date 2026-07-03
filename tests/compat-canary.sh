#!/usr/bin/env bash
#
# Weekly tripwire (PRD §8.6): diff the live Claude Code docs against the stored
# raw baselines under docs/upstream-snapshots/raw/. If the hooks / statusline /
# plugins / marketplace pages changed, open a GitHub issue pointing at the
# severance-compat-check skill. It does NOT update the baseline — a human does,
# via the skill and a PR. Requires: curl, gh (GH_TOKEN).
#
set -euo pipefail

BASE="https://code.claude.com/docs/en"
RAW="docs/upstream-snapshots/raw"
pages=(hooks statusline plugins-reference plugin-marketplaces)
changed=()

for page in "${pages[@]}"; do
	stored="$RAW/$page.md"
	if [ ! -f "$stored" ]; then
		echo "no baseline for $page"
		continue
	fi
	live="$(mktemp)"
	if ! curl -fsSL "$BASE/$page.md" -o "$live"; then
		echo "fetch failed: $page (skipping)"
		rm -f "$live"
		continue
	fi
	if diff -q "$live" "$stored" >/dev/null 2>&1; then
		echo "ok: $page"
	else
		echo "CHANGED: $page"
		changed+=("$page")
	fi
	rm -f "$live"
done

if [ "${#changed[@]}" -eq 0 ]; then
	echo "no upstream changes"
	exit 0
fi

title="Upstream Claude Code docs changed — run /severance:severance-compat-check"
body="The weekly compat canary detected changes in: ${changed[*]}.

Run the \`severance-compat-check\` skill to diff the new shapes against the
normalizer / fixtures / schemas, refresh docs/upstream-snapshots/ (including the
raw baselines under raw/), and open a conventional-commit PR."

if [ "$(gh issue list --state open --search "$title in:title" --json number --jq 'length' 2>/dev/null || echo 0)" != "0" ]; then
	echo "an open compat issue already exists"
	exit 0
fi
gh issue create --title "$title" --body "$body"
