#!/usr/bin/env bash
#
# Validate the plugin manifests against the vendored minimal schemas
# (schemas/vendor/). Authoritative validation is `claude plugin validate
# --strict`; this is the lightweight, dependency-free CI check (PRD §8.1).
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
V="$ROOT/schemas/vendor"

echo "== vendor schema self-check =="
check-jsonschema --check-metaschema "$V"/*.json

echo "== manifests =="
declare -a pairs=(
	"$V/plugin-manifest.schema.json|$ROOT/plugin/.claude-plugin/plugin.json"
	"$V/hooks.schema.json|$ROOT/plugin/hooks/hooks.json"
	"$V/marketplace.schema.json|$ROOT/.claude-plugin/marketplace.json"
)
fail=0
for pair in "${pairs[@]}"; do
	schema="${pair%%|*}"
	file="${pair##*|}"
	if check-jsonschema --schemafile "$schema" "$file" >/dev/null 2>&1; then
		echo "  ok      ${file#"$ROOT"/}"
	else
		echo "  FAIL    ${file#"$ROOT"/}"
		check-jsonschema --schemafile "$schema" "$file" 2>&1 | sed 's/^/            /'
		fail=1
	fi
done

exit "$fail"
