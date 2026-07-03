#!/usr/bin/env bash
#
# Assert every commit subject in <base>..<head> follows Conventional Commits
# (PRD §8.3). Used by the commitlint PR check. Merge commits are skipped.
#
set -euo pipefail

base="${1:?usage: check-conventional-commits.sh <base-sha> <head-sha>}"
head="${2:?usage: check-conventional-commits.sh <base-sha> <head-sha>}"

pattern='^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([^)]+\))?!?: .+'
fail=0

while IFS= read -r subject; do
	[ -z "$subject" ] && continue
	case "$subject" in "Merge "*) continue ;; esac
	if printf '%s' "$subject" | grep -Eq "$pattern"; then
		echo "ok:  $subject"
	else
		echo "BAD: $subject"
		fail=1
	fi
done < <(git log --format='%s' "$base..$head")

if [ "$fail" -ne 0 ]; then
	echo
	echo "Commit subjects must be Conventional Commits, e.g. 'feat(scripts): add gate'."
fi
exit "$fail"
