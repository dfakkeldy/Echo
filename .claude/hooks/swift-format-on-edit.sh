#!/bin/bash
# PostToolUse formatter: run `swift format` on a just-edited Swift file.
#
# Echo had no formatter configured, so style drifted across 400+ files. This
# hook formats only the file Claude just touched, using the repo's .swift-format
# config (4-space, tuned to the existing style) so diffs stay minimal.
#
# Contract (see .claude/settings.json): receives the PostToolUse event JSON on
# stdin; the edited path is at .tool_input.file_path. This is a pure, best-effort
# side-effect: it ALWAYS exits 0 and never disrupts the edit.
#
# It deliberately does nothing unless ALL of these hold:
#   * the off-switch env ECHO_DISABLE_SWIFT_FORMAT is unset,
#   * the edited file ends in .swift and exists,
#   * a .swift-format config exists at the project root (delete it to opt out),
#   * the `swift format` toolchain subcommand is available.
set -uo pipefail

# Off-switch: lets you silence formatting for a session without editing config.
[[ -n "${ECHO_DISABLE_SWIFT_FORMAT:-}" ]] && exit 0

command -v jq >/dev/null 2>&1 || exit 0
file="$(jq -r '.tool_input.file_path // empty' 2>/dev/null)" || exit 0
[[ -z "$file" ]] && exit 0
[[ "$file" == *.swift ]] || exit 0
[[ -f "$file" ]] || exit 0

project_dir="${CLAUDE_PROJECT_DIR:-$(pwd)}"
config="$project_dir/.swift-format"
[[ -f "$config" ]] || exit 0            # config-gated opt-out

command -v swift >/dev/null 2>&1 || exit 0
# `swift format` exists only on Swift 5.8+ toolchains; probe quietly.
swift format --version >/dev/null 2>&1 || exit 0

swift format --in-place --configuration "$config" "$file" >/dev/null 2>&1 || true
exit 0
