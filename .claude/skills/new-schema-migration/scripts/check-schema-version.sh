#!/bin/bash
# Reports Echo's current max GRDB schema version and the next free one, and flags
# inconsistencies that cause migration bugs:
#   * a Schema_Vxx enum that is never registered in DatabaseService (dead migration)
#   * a registerMigration("vxx_…") with no matching Schema_Vxx enum
#   * duplicate version numbers (the classic merge collision)
#
# Usage: bash .claude/skills/new-schema-migration/scripts/check-schema-version.sh
set -uo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
DBSVC="$ROOT/Shared/Database/DatabaseService.swift"
DBDIR="$ROOT/Shared/Database"

[[ -f "$DBSVC" ]] || { echo "ERROR: $DBSVC not found (run from the Echo repo)"; exit 1; }

# Version numbers registered in the migrator, e.g. registerMigration("v16_fsrs…").
# Skip commented-out lines so a disabled registration isn't counted as live.
registered="$(grep -vE '^[[:space:]]*//' "$DBSVC" | grep -oE 'registerMigration\("v[0-9]+' | grep -oE '[0-9]+' | sort -n)"
# Version numbers that have a Schema_Vxx enum (whole subtree, incl. Migrations/).
# Assumes the convention `enum Schema_Vxx` on a single line (true for all current migrations).
enums="$(grep -rhoE 'enum Schema_V[0-9]+' "$DBDIR" | grep -oE '[0-9]+' | sort -n)"

max_reg="$(echo "$registered" | tail -1)"
max_enum="$(echo "$enums" | tail -1)"
max_all="$(printf '%s\n%s\n' "$registered" "$enums" | grep -E '^[0-9]+$' | sort -n | tail -1)"
: "${max_all:=0}"
next=$((max_all + 1))

echo "Current max registered migration : V${max_reg:-none}"
echo "Current max Schema_Vxx enum      : V${max_enum:-none}"
echo "==> Next free version            : V${next}   (identifier: \"v${next}_<short_description>\")"
echo ""

problems=0

dupes="$(echo "$registered" | uniq -d)"
if [[ -n "$dupes" ]]; then
  echo "🔴 DUPLICATE registered versions: $(echo $dupes)"
  problems=$((problems+1))
fi

# enums present but not registered
while read -r v; do
  [[ -z "$v" ]] && continue
  if ! echo "$registered" | grep -qx "$v"; then
    echo "🔴 Schema_V${v} exists but is NOT registered in DatabaseService.swift"
    problems=$((problems+1))
  fi
done <<< "$enums"

# registered but no enum
while read -r v; do
  [[ -z "$v" ]] && continue
  if ! echo "$enums" | grep -qx "$v"; then
    echo "🔴 registerMigration(\"v${v}_…\") has no matching 'enum Schema_V${v}'"
    problems=$((problems+1))
  fi
done <<< "$registered"

if [[ "$problems" -eq 0 ]]; then
  if [[ "$max_all" -gt 0 ]]; then
    echo "✓ Registrations and Schema_Vxx enums are consistent (V1…V${max_all})."
  else
    echo "✓ No migrations defined yet."
  fi
fi
exit 0
