# Claude Code Guidelines for Echo

@AGENTS.md

## Project context

- Echo is an open-source audiobook study player (GPL-3.0) for iOS, watchOS, and
  macOS, with widget targets and shared logic under `Shared/`.
- The Python tools generate transcripts; in-app alignment uses WhisperKit.
- `AutoAlignmentService` combines chapter-title matching with content alignment.
  Preserve its convergence rule: each run replaces its previous automatic
  anchors.
- Audio-only transcription, source-backed alignment, generated narration QA,
  pronunciation repair, and macOS parity are distinct acceptance surfaces.

## Architecture notes

- Follow the concrete injection pattern used by `DatabaseService(inMemory:)`.
  The former unused playback/store protocols and orphaned mocks were removed;
  do not recreate them without a real injected consumer.
- Exercise new logic through concrete in-memory services or another established
  seam. Do not refer to deleted mock files.
- Keep parameterized database access and heavy media work off the UI actor.
- Update `README.md` or `ARCHITECTURE.md` only when a change makes their current
  description inaccurate.

## Release and build notes

- The promotion ladder and publication rules are canonical in `AGENTS.md`.
- CI's `Build gate + tests` protects all three promotion branches; scheduled
  release trains build `nightly` daily and `weekly` on Mondays.
- Use `make test` for unit tests and `make echo-cli` for the command-line tool.
  Do not substitute a bare `xcodebuild -scheme echo-cli`; the Make target pins
  the required release and incremental compilation settings.
