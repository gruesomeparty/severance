#!/usr/bin/env bash
#
# Lint plugin SKILL.md files (PRD §8.1 skill-lint):
#   - starts with a YAML frontmatter block (--- ... ---)
#   - frontmatter has non-empty `name:` and `description:`
#   - description is a reasonable length (<= 1024 chars)
#   - whole file is under 500 lines
#
# Passes cleanly when no SKILL.md exists yet (skills land in M4).
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILLS_DIR="$ROOT/plugin/skills"
MAX_LINES=500
MAX_DESC=1024

mapfile -t skills < <(find "$SKILLS_DIR" -name SKILL.md 2>/dev/null | sort)

if [[ ${#skills[@]} -eq 0 ]]; then
	echo "no SKILL.md files under plugin/skills/ yet — nothing to lint"
	exit 0
fi

# Print the YAML frontmatter (lines between the first two --- fences).
frontmatter() {
	awk 'NR==1 && $0=="---"{f=1;next} f && $0=="---"{exit} f{print}' "$1"
}

# Read a scalar frontmatter field ("name"/"description"), trimmed.
field() {
	awk -v k="$1" '
    $0 ~ "^" k ":" {
      sub("^" k ":[ \t]*", "")
      gsub(/^[ \t]+|[ \t]+$/, "")
      print
      exit
    }' <<<"$2"
}

fail=0
for s in "${skills[@]}"; do
	rel="${s#"$ROOT"/}"
	fm="$(frontmatter "$s")"

	if [[ -z "$fm" ]]; then
		echo "FAIL $rel: no YAML frontmatter block"
		fail=1
		continue
	fi

	name="$(field name "$fm")"
	desc="$(field description "$fm")"

	[[ -n "$name" ]] || {
		echo "FAIL $rel: missing or empty 'name'"
		fail=1
	}
	[[ -n "$desc" ]] || {
		echo "FAIL $rel: missing or empty 'description'"
		fail=1
	}
	if [[ -n "$desc" && ${#desc} -gt $MAX_DESC ]]; then
		echo "FAIL $rel: description too long (${#desc} > $MAX_DESC chars)"
		fail=1
	fi

	lines="$(wc -l <"$s" | tr -d ' ')"
	if [[ "$lines" -ge "$MAX_LINES" ]]; then
		echo "FAIL $rel: $lines lines (must be < $MAX_LINES)"
		fail=1
	fi

	[[ "$fail" -eq 0 ]] && echo "ok   $rel (name='$name', ${#desc} desc chars, $lines lines)"
done

exit "$fail"
