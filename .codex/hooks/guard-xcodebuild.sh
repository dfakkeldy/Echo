#!/bin/bash
# PreToolUse guard: enforce Echo's RAM-safety rules for xcodebuild on this 16 GB machine.
#
# Echo's CLAUDE.md states: "never run xcodebuild with parallel testing enabled or
# uncapped -jobs, and never run two xcodebuild invocations concurrently."
# This hook turns that prose rule into a hard block so an accidental ad-hoc
# xcodebuild can't swap the machine to a crawl.
#
# Contract (see .claude/settings.json): receives the PreToolUse event JSON on
# stdin; the Bash command is at .tool_input.command. To BLOCK, we print a
# permissionDecision:"deny" object to stdout and exit 0. To ALLOW, we print
# nothing and exit 0. stdout must be JSON-only or empty.
#
# It is SEGMENT-AWARE on purpose. A naive single-blob grep is trivially bypassed
# (decoy `-jobs 1` in a quoted -scheme, a second chained `xcodebuild test` that
# borrows the first segment's serial flag, two heavy builds joined with `&`).
# So we: (1) join backslash line-continuations, (2) blank quoted spans so decoys
# and stray words inside -scheme/-destination can't trigger or hide rules,
# (3) split on shell separators (&& || ; & | newline) and apply the rules to
# each xcodebuild segment independently, and (4) count heavy invocations so two
# concurrent builds in one command line are caught.
#
# Design notes:
#  * Only direct `xcodebuild` invocations are inspected. `make test` /
#    `make build-tests` bake in the safe flags, so they pass untouched.
#  * Fail OPEN: if jq is missing or parsing fails we allow. A broken guard must
#    never block every Bash call.
#  * The "another xcodebuild already running" check is injectable via
#    _GUARD_FAKE_XCODEBUILD_RUNNING for deterministic testing.
#  * BSD/macOS sed turns `\n` in a replacement into a literal 'n', so all
#    newline insertion is done in bash (`$'\n'`); sed is used only for
#    substitution-to-space, which is portable.
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0
cmd="$(jq -r '.tool_input.command // empty' 2>/dev/null)" || exit 0
[[ -z "$cmd" ]] && exit 0
[[ "$cmd" != *xcodebuild* ]] && exit 0      # fast path: not our concern

deny() {
  jq -n --arg reason "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
  exit 0
}

running_count() {
  if [[ -n "${_GUARD_FAKE_XCODEBUILD_RUNNING:-}" ]]; then
    printf '%s' "$_GUARD_FAKE_XCODEBUILD_RUNNING"
  else
    pgrep -x xcodebuild 2>/dev/null | grep -c . || true
  fi
}

# 1) Join backslash line-continuations ("\<newline>" -> space) so a -jobs value
#    on a continued line is seen as one token.
flat="${cmd//\\$'\n'/ }"

# 2) Blank the contents of quoted spans (per-line; replacement is a space, which
#    is BSD-safe — the `:a;N;$!ba` slurp idiom mis-handles a final line without a
#    trailing newline on BSD sed and would blank the whole command). Quoted args
#    don't span newlines, so per-line is correct and we split on newlines next.
flat="$(printf '%s' "$flat" | sed -e 's/"[^"]*"/ /g' -e "s/'[^']*'/ /g")"

# 3) Turn shell separators into newlines (bash, BSD-safe). Two-char operators
#    first so the single-char pass doesn't mangle them.
flat="${flat//&&/$'\n'}"
flat="${flat//||/$'\n'}"
flat="${flat//;/$'\n'}"
flat="${flat//&/$'\n'}"
flat="${flat//|/$'\n'}"

# 4) Apply the rules per xcodebuild segment.
heavy_count=0
violation=""
viol_detail=""

while IFS= read -r seg; do
  seg="${seg%%#*}"                                   # drop trailing comment
  grep -qE '(^|[[:space:]])xcodebuild([[:space:]]|$)' <<<"$seg" || continue

  runs_tests=0
  if grep -qE '(^|[[:space:]])test([[:space:]]|$)' <<<"$seg" || [[ "$seg" == *test-without-building* ]]; then
    runs_tests=1
  fi

  is_heavy=0
  if [[ "$runs_tests" -eq 1 ]] \
     || grep -qE '(^|[[:space:]])(build|archive|docbuild)([[:space:]]|$)' <<<"$seg" \
     || [[ "$seg" == *build-for-testing* ]]; then
    is_heavy=1
    heavy_count=$((heavy_count + 1))
  fi

  # Rule 1: parallel testing explicitly enabled.
  if grep -qE '\-parallel-testing-enabled[[:space:]=]+YES' <<<"$seg"; then
    violation="parallel_yes"; break
  fi
  # Rule 2: a test-running action must explicitly disable parallel testing.
  if [[ "$runs_tests" -eq 1 ]] && ! grep -qE '\-parallel-testing-enabled[[:space:]=]+NO' <<<"$seg"; then
    violation="parallel_missing"; break
  fi
  # Rule 3: -jobs must be capped at 5 — inspect the MAX of all -jobs values.
  maxjobs="$(grep -oE '\-jobs[[:space:]=]+[0-9]+' <<<"$seg" | grep -oE '[0-9]+' | sort -rn | head -1)"
  if [[ -n "$maxjobs" && "$maxjobs" -gt 5 ]]; then
    violation="jobs"; viol_detail="$maxjobs"; break
  fi
done <<< "$flat"

case "$violation" in
  parallel_yes)
    deny "Echo runs on a 16 GB machine: parallel testing is forbidden (CLAUDE.md). Use '-parallel-testing-enabled NO', or run 'make test'." ;;
  parallel_missing)
    deny "Echo's test runs must pass '-parallel-testing-enabled NO' on this 16 GB machine (CLAUDE.md). Prefer 'make test' / 'make test-only', which set it for you. (Each chained 'xcodebuild test' needs its own flag.)" ;;
  jobs)
    deny "Echo caps xcodebuild at '-jobs 5' on this 16 GB machine (CLAUDE.md); this command requests -jobs $viol_detail. Lower it to 5 or fewer." ;;
esac

# Rule 4a: one command line that launches two+ heavy xcodebuild invocations.
if [[ "$heavy_count" -ge 2 ]]; then
  deny "This command starts $heavy_count concurrent xcodebuild builds; Echo's CLAUDE.md forbids concurrent builds on this 16 GB machine. Run them one at a time."
fi

# Rule 4b: a heavy invocation while another xcodebuild is already running.
if [[ "$heavy_count" -ge 1 ]]; then
  running="$(running_count)"
  running="${running:-0}"
  if [[ "$running" =~ ^[0-9]+$ && "$running" -gt 0 ]]; then
    deny "Another xcodebuild is already running; Echo's CLAUDE.md forbids concurrent builds on this 16 GB machine. Wait for it to finish (or kill the stale process) before starting another."
  fi
fi

exit 0
