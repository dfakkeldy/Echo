# Task 2 report

## RED evidence

`XBG_ALLOW_NOW=1 /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests`
failed as expected before implementation: `voicePlanURL` was an extra argument,
`nil` could not be passed for `VoiceID`, and `legacyDefaultVoice` was missing.
This was a compile RED, so no executable test count was available.

## Implementation

- `NarrationRunConfig.voice` is optional and has `voicePlanURL`.
- Runner rejects plan/PDF-or-directory and plan/chapter combinations before
  acquiring a lease or creating/touching the configured work directory.
- Runner resolves/decode-validates plan after imported chapters and before
  fresh cleanup, and checks plan voice resources.
- CLI accepts `--voice-plan`, has optional `--voice`, and registers a
  read-only `resolve-voice-plan` command.
- Added runner and read-only resolver helper tests.

## GREEN evidence

The fresh post-change `make build-tests` completed with `** TEST BUILD SUCCEEDED **`.

`make test-only FILTER=EchoTests/HeadlessNarrationRunnerTests` completed with
`totalTestCount: 54`, `passedTests: 54`, `failedTests: 0`.

The new resolver suite first failed with `totalTestCount: 2`, `passedTests: 1`,
`failedTests: 1`: database-free parsing left all `chapterIndex` fields nil, so
the chapter planner emitted no blocks. The smallest fix maps its canonical
spine index into `chapterIndex` only in the temporary, read-only resolver
parse. The rerun completed with `totalTestCount: 2`, `passedTests: 2`, and
`failedTests: 0`.

`make echo-cli` completed successfully after explicitly selecting
`VoiceID(rawValue:)` (both unlabeled and `rawValue` initializers exist).
The Release binary reports `--voice-plan` for `narrate` and both required
`--epub` / `--voice-plan` options for `resolve-voice-plan`.

## Self-review

- Plan/PDF-or-directory and plan/chapter options reject before runner lease or
  configured-work-directory mutation; plan resolution/resource validation runs
  before fresh cleanup.
- The resolver opens no database and removes its temporary extraction directory
  before returning; its test asserts caller-directory contents are unchanged.
- `git diff --check` completed without whitespace errors.
- The command is implemented in `EchoCLI.swift`, because the CLI target has an
  explicit source list; no project-file change was needed.

## Concerns

Task 3 will replace Task 2's temporary plan-default chapter voice bridge with
the required per-original-block voice closure. Task 2 deliberately does not
modify that rendering interface.

## Commit

`bfb4d72a` — `feat(cli): accept source-bound voice plans`

## Fix round 1

- Resolver stdout now uses the exact compact, sorted-key identity contract.
- Resolver shares EPUBImportService TOC resolution and structure chaptering, validates bundled voice resources, and rejects archive path escape.
- Added regression coverage for identity JSON, containment, TOC range boundaries, missing resources, and fail-closed plan cleanup.
- Fresh verification: `make build-tests`; resolver and runner focused suites; `make echo-cli`; CLI help confirms required options.

## Fix round 2

### RED evidence

After adding the three command-path tests,
`XBG_ALLOW_NOW=1 /Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests`
failed as intended with three `cannot find 'ResolveVoicePlanCommand' in scope`
errors in `ResolveVoicePlanCommandTests`. This controlled compile RED proved the
tests required a command-level seam rather than exercising only
`HeadlessNarrationRunner` helpers.

### Command-level coverage

- `ResolveVoicePlanCommand.run` now owns the CLI action: resolve the source-bound
  plan, encode its canonical identity, and write exactly one stdout line through
  an injected output closure. The `AsyncParsableCommand` wrapper delegates to
  that action without adding behavior.
- The success test executes that action against a real archived EPUB and plan,
  derives the expected canonical block-map SHA-256 independently, and compares
  the full compact identity JSON byte-for-byte.
- Separate invalid-source and malformed-plan tests assert that the command action
  throws and writes no stdout. The Release executable separately returned status
  `1` and `Error: Invalid voice plan: --voice-plan requires an EPUB file` for an
  invalid source.

### GREEN evidence

`make build-tests` completed with `** TEST BUILD SUCCEEDED **` after the
main-actor annotation matched the runner's isolation.

`make test-only FILTER=EchoTests/ResolveVoicePlanCommandTests` completed with
`totalTestCount: 9`, `passedTests: 9`, `failedTests: 0`.

`make test-only FILTER=EchoTests/HeadlessNarrationRunnerTests` completed with
`totalTestCount: 58`, `passedTests: 58`, `failedTests: 0`. This suite includes
the two fail-closed tests added in `5818375e`:
`planWithConflictingExplicitVoiceFailsBeforeFreshCleanup` and
`planWithDirectorySourceFailsBeforeFreshCleanup`.

`make echo-cli` completed successfully. The Release binary's
`resolve-voice-plan --help` output includes required `--epub` and `--voice-plan`
options; its invalid-source invocation exited with status `1` as described
above.

### Self-review

- The shared command action is intentionally the smallest testable seam for the
  iOS test bundle, which cannot launch the macOS CLI executable. It is called by
  the registered CLI subcommand, so the tested resolve-and-write behavior is the
  same behavior the executable uses.
- The exact-output expectation is independently built from the documented
  sorted-key canonical shape; it does not call the production identity encoder.
- `git diff --check` completed without whitespace errors. No generated audio,
  archives, or private content is included.
