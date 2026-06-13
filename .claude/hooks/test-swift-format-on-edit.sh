#!/bin/bash
# Test harness for swift-format-on-edit.sh (PostToolUse formatter).
# Verifies the GATING logic: it must format .swift files only when a project
# .swift-format config is present and the off-switch is unset — and must NEVER
# touch anything else or error on edits.
#
# Run:  bash .claude/hooks/test-swift-format-on-edit.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/swift-format-on-edit.sh"

pass=0; fail=0
MESSY='struct A{let x:Int
func y( )->Int{return x}}'

payload() { jq -n --arg fp "$1" '{tool_name: "Edit", tool_input: {file_path: $fp}}'; }

check() { # check <desc> <expect: changed|unchanged> <file> <original>
  local desc="$1" expect="$2" file="$3" orig="$4" now
  now="$(cat "$file" 2>/dev/null)"
  if [[ "$expect" == "changed" && "$now" != "$orig" ]] \
     || [[ "$expect" == "unchanged" && "$now" == "$orig" ]]; then
    pass=$((pass+1)); printf '  ok   %-9s | %s\n' "$expect" "$desc"
  else
    fail=$((fail+1)); printf '  FAIL %-9s | %s\n' "$expect" "$desc"
  fi
}

cfg='{ "version": 1, "lineLength": 100, "indentation": { "spaces": 4 }, "tabWidth": 4 }'

# --- Sandbox WITH a .swift-format config ---
S1="$(mktemp -d)"; printf '%s' "$cfg" > "$S1/.swift-format"

# NOTE: env vars must bind to the hook (right of the pipe), not to `payload`.
printf '%s' "$MESSY" > "$S1/a.swift"
payload "$S1/a.swift" | CLAUDE_PROJECT_DIR="$S1" bash "$HOOK" >/dev/null 2>&1
check ".swift file, config present -> formatted" changed "$S1/a.swift" "$MESSY"

printf '%s' "$MESSY" > "$S1/b.txt"
payload "$S1/b.txt" | CLAUDE_PROJECT_DIR="$S1" bash "$HOOK" >/dev/null 2>&1
check "non-.swift file -> untouched" unchanged "$S1/b.txt" "$MESSY"

printf '%s' "$MESSY" > "$S1/c.swift"
payload "$S1/c.swift" | ECHO_DISABLE_SWIFT_FORMAT=1 CLAUDE_PROJECT_DIR="$S1" bash "$HOOK" >/dev/null 2>&1
check "off-switch ECHO_DISABLE_SWIFT_FORMAT=1 -> untouched" unchanged "$S1/c.swift" "$MESSY"

# --- Sandbox WITHOUT a .swift-format config (config-gated opt-out) ---
S2="$(mktemp -d)"
printf '%s' "$MESSY" > "$S2/d.swift"
payload "$S2/d.swift" | CLAUDE_PROJECT_DIR="$S2" bash "$HOOK" >/dev/null 2>&1
check "no .swift-format config -> untouched" unchanged "$S2/d.swift" "$MESSY"

# --- Missing file path must not error and must exit 0 ---
payload "$S1/does-not-exist.swift" | CLAUDE_PROJECT_DIR="$S1" bash "$HOOK" >/dev/null 2>&1
code=$?
if [[ "$code" -eq 0 ]]; then
  pass=$((pass+1)); printf '  ok   exit0     | missing file -> no error, exit 0\n'
else
  fail=$((fail+1)); printf '  FAIL exit0     | missing file -> exit %s\n' "$code"
fi

rm -rf "$S1" "$S2"
echo ""
printf "Passed: %d   Failed: %d\n" "$pass" "$fail"
[[ "$fail" -eq 0 ]]
