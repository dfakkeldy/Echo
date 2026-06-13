#!/bin/bash
# Test harness for guard-xcodebuild.sh (the PreToolUse RAM-safety guard).
#
# This is the TDD spec for the guard. Each case feeds a realistic Bash command
# (wrapped in the PreToolUse stdin JSON shape) to the guard and asserts whether
# the guard ALLOWS (empty stdout, exit 0) or DENIES (permissionDecision: deny).
#
# Run:  bash .claude/hooks/test-guard-xcodebuild.sh
# Exits non-zero if any assertion fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/guard-xcodebuild.sh"

# Make the suite hermetic: the "another xcodebuild already running" check uses
# real `pgrep` by default, which would make heavy-build ALLOW cases flaky if any
# xcodebuild happens to be running on the machine. Pin it to 0 here; the
# concurrency cases below override it inline to exercise the real-running path.
export _GUARD_FAKE_XCODEBUILD_RUNNING=0

pass=0
fail=0

# Build the PreToolUse stdin JSON for a Bash command, safely encoding quotes.
make_payload() {
  jq -n --arg cmd "$1" '{tool_name: "Bash", tool_input: {command: $cmd}}'
}

# run_guard <command> -> sets $OUT (stdout) and $CODE (exit status)
run_guard() {
  OUT="$(make_payload "$1" | bash "$GUARD" 2>/dev/null)"
  CODE=$?
}

assert_deny() {
  local desc="$1" cmd="$2"
  run_guard "$cmd"
  if [[ "$CODE" -eq 0 && "$OUT" == *'"permissionDecision"'* && "$OUT" == *'"deny"'* ]]; then
    pass=$((pass+1)); printf '  ok   DENY  | %s\n' "$desc"
  else
    fail=$((fail+1)); printf '  FAIL DENY  | %s\n        expected deny, got exit=%s out=<%s>\n' "$desc" "$CODE" "$OUT"
  fi
}

assert_allow() {
  local desc="$1" cmd="$2"
  run_guard "$cmd"
  if [[ "$CODE" -eq 0 && "$OUT" != *'"deny"'* ]]; then
    pass=$((pass+1)); printf '  ok   ALLOW | %s\n' "$desc"
  else
    fail=$((fail+1)); printf '  FAIL ALLOW | %s\n        expected allow, got exit=%s out=<%s>\n' "$desc" "$CODE" "$OUT"
  fi
}

echo "== Non-xcodebuild commands: always allowed =="
assert_allow "plain git command"            'git status'
assert_allow "make test (flags encoded in target, no literal xcodebuild)" 'make test'
assert_allow "make build-tests"             'make build-tests FILTER=EchoTests/TOCTreeBuilderTests'

echo "== Lightweight xcodebuild actions: allowed =="
assert_allow "xcodebuild -version"          'xcodebuild -version'
assert_allow "xcodebuild -list -json"       'xcodebuild -project Echo.xcodeproj -list -json'
assert_allow "resolve package deps"         'xcodebuild -resolvePackageDependencies -project Echo.xcodeproj -scheme "Echo macOS"'
assert_allow "showBuildSettings"            'xcodebuild -showBuildSettings -scheme Echo'

echo "== Safe heavy builds (match Makefile / CI patterns): allowed =="
assert_allow "CI macOS build (lone build, no -jobs)" 'xcodebuild build -project Echo.xcodeproj -scheme "Echo macOS" -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO -quiet'
assert_allow "Makefile test (serial + jobs 5)" "xcodebuild test -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:EchoTests -parallel-testing-enabled NO -jobs 5"
assert_allow "CI iOS test (serial, no -jobs)"  'xcodebuild test -project Echo.xcodeproj -scheme "Echo" -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:EchoTests -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO -quiet'
assert_allow "build-for-testing with jobs 5"   "xcodebuild build-for-testing -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 17' -jobs 5"
assert_allow "test-without-building serial"    'xcodebuild test-without-building -scheme Echo -only-testing:EchoTests -parallel-testing-enabled NO'

echo "== Parallel testing: denied =="
assert_deny  "test action missing -parallel-testing-enabled NO" "xcodebuild test -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:EchoTests"
assert_deny  "explicit -parallel-testing-enabled YES"           'xcodebuild test -scheme Echo -parallel-testing-enabled YES'
assert_deny  "test-without-building missing serial flag"        'xcodebuild test-without-building -scheme Echo -only-testing:EchoTests'

echo "== Uncapped / over-cap -jobs: denied =="
assert_deny  "build with -jobs 12"                  'xcodebuild build -scheme Echo -jobs 12'
assert_deny  "serial test but -jobs 8 (>5)"         'xcodebuild test -scheme Echo -parallel-testing-enabled NO -jobs 8'
assert_allow "build with -jobs 4 (<=5)"             'xcodebuild build -scheme Echo -jobs 4'

echo "== Concurrent xcodebuild invocation: denied for heavy actions =="
_GUARD_FAKE_XCODEBUILD_RUNNING=1 run_guard 'xcodebuild build -scheme "Echo macOS" -destination platform=macOS'
if [[ "$CODE" -eq 0 && "$OUT" == *'"deny"'* ]]; then
  pass=$((pass+1)); printf '  ok   DENY  | heavy build while another xcodebuild running\n'
else
  fail=$((fail+1)); printf '  FAIL DENY  | heavy build while another xcodebuild running (exit=%s out=<%s>)\n' "$CODE" "$OUT"
fi

_GUARD_FAKE_XCODEBUILD_RUNNING=1 run_guard 'xcodebuild -version'
if [[ "$CODE" -eq 0 && "$OUT" != *'"deny"'* ]]; then
  pass=$((pass+1)); printf '  ok   ALLOW | lightweight -version even while another xcodebuild running\n'
else
  fail=$((fail+1)); printf '  FAIL ALLOW | lightweight -version while another running (exit=%s out=<%s>)\n' "$CODE" "$OUT"
fi

_GUARD_FAKE_XCODEBUILD_RUNNING=0 run_guard 'xcodebuild build -scheme "Echo macOS" -destination platform=macOS'
if [[ "$CODE" -eq 0 && "$OUT" != *'"deny"'* ]]; then
  pass=$((pass+1)); printf '  ok   ALLOW | heavy build when nothing else running\n'
else
  fail=$((fail+1)); printf '  FAIL ALLOW | heavy build when nothing else running (exit=%s out=<%s>)\n' "$CODE" "$OUT"
fi

echo "== Adversarial: false positives that must be ALLOWED (quoted args / comments) =="
assert_allow "'test' inside -destination simulator name"  'xcodebuild -showBuildSettings -destination "platform=iOS Simulator,name=iPhone test rig"'
assert_allow "'test' only in a trailing # comment"        'xcodebuild -version # run before test'
assert_allow "build/test words only inside a quoted echo"  'echo "run the test harness for xcodebuild before build"'
assert_allow "decoy -jobs in quoted scheme, real -jobs 4"  "xcodebuild test -scheme \"Echo -jobs 1\" -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:EchoTests -parallel-testing-enabled NO -jobs 4"

echo "== Adversarial: bypasses that must be DENIED (decoys / chaining / concurrency) =="
assert_deny  "decoy low -jobs 5 then real -jobs 99"        'xcodebuild build -scheme Echo -jobs 5 -jobs 99'
assert_deny  "decoy -jobs in quoted scheme, real -jobs 32" 'xcodebuild test -scheme "Echo -jobs 1" -parallel-testing-enabled NO -jobs 32'
assert_deny  "two heavy builds joined with & (concurrent)"  'xcodebuild build -scheme A -destination platform=macOS & xcodebuild build -scheme B -destination platform=macOS'
assert_deny  "chained tests, 2nd lacks serial flag"        'xcodebuild test -scheme A -parallel-testing-enabled NO && xcodebuild test -scheme B -only-testing:EchoTests'
assert_deny  "two heavy via ; even with serial flags"      'xcodebuild test -scheme A -parallel-testing-enabled NO ; xcodebuild test -scheme B -parallel-testing-enabled NO'

# Backslash line-continuation joins -jobs with its value -> must be capped.
run_guard "$(printf 'xcodebuild build -scheme Echo -jobs \\\n99')"
if [[ "$CODE" -eq 0 && "$OUT" == *'"deny"'* ]]; then
  pass=$((pass+1)); printf '  ok   DENY  | backslash-continuation -jobs \\<newline>99\n'
else
  fail=$((fail+1)); printf '  FAIL DENY  | backslash-continuation -jobs (exit=%s out=<%s>)\n' "$CODE" "$OUT"
fi

# A bare newline DOES separate commands in a real shell, so `-jobs` then `99`
# on the next line is NOT a 99-job build; it must remain ALLOWED (not a bypass).
run_guard "$(printf 'xcodebuild build -scheme Echo -jobs\n99')"
if [[ "$CODE" -eq 0 && "$OUT" != *'"deny"'* ]]; then
  pass=$((pass+1)); printf '  ok   ALLOW | bare-newline split -jobs (not a real 99-job run)\n'
else
  fail=$((fail+1)); printf '  FAIL ALLOW | bare-newline split -jobs (exit=%s out=<%s>)\n' "$CODE" "$OUT"
fi

echo ""
echo "==================================="
printf "Passed: %d   Failed: %d\n" "$pass" "$fail"
echo "==================================="
[[ "$fail" -eq 0 ]]
