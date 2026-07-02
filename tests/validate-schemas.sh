#!/usr/bin/env bash
#
# Validate Severance's JSON Schemas and their fixtures.
#
#   1. metaschema-check every schema in schemas/
#   2. for each fixtures/<name>/ dir, validate against schemas/<name>.schema.json:
#        - every valid/*.json   MUST pass
#        - every invalid/*.json MUST be rejected (isolates one contract violation)
#
# Used locally (`bash tests/validate-schemas.sh`) and by the validate-json CI job,
# so local and CI results are identical. Requires: check-jsonschema.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEMA_DIR="$ROOT/schemas"
FIX_DIR="$ROOT/tests/fixtures"

fail=0

echo "== metaschema self-check =="
check-jsonschema --check-metaschema "$SCHEMA_DIR"/*.json

echo
echo "== fixtures =="
for dir in "$FIX_DIR"/*/; do
	name="$(basename "$dir")"
	schema="$SCHEMA_DIR/$name.schema.json"
	if [[ ! -f "$schema" ]]; then
		echo "MISSING SCHEMA for fixtures/$name (expected $schema)"
		fail=1
		continue
	fi

	if compgen -G "$dir/valid/*.json" >/dev/null; then
		for f in "$dir"valid/*.json; do
			if out="$(check-jsonschema --schemafile "$schema" "$f" 2>&1)"; then
				echo "  ok      valid   $name/$(basename "$f")"
			else
				echo "  FAIL    valid   $name/$(basename "$f")  (should PASS)"
				awk '{print "            " $0}' <<<"$out"
				fail=1
			fi
		done
	fi

	if compgen -G "$dir/invalid/*.json" >/dev/null; then
		for f in "$dir"invalid/*.json; do
			if check-jsonschema --schemafile "$schema" "$f" >/dev/null 2>&1; then
				echo "  FAIL    invalid $name/$(basename "$f")  (should be REJECTED)"
				fail=1
			else
				echo "  ok      invalid $name/$(basename "$f")"
			fi
		done
	fi
done

echo
if [[ "$fail" -eq 0 ]]; then
	echo "schema validation: PASS"
else
	echo "schema validation: FAIL"
fi
exit "$fail"
