# Claude Code Guidelines for Echo: Audiobook Study Player

<!-- Loads the repo's AGENTS.md (modern Swift/SwiftUI rules + Echo branch/PR workflow) alongside this file.
     Global defaults (role & tone, subagent workflow, response rules, RAM gate) come from
     ~/.claude/CLAUDE.md — do not duplicate them here. -->
@AGENTS.md

## Project Context
* **App:** Open-source media player app (GPL-3.0 License).
* **Targets:** iOS, watchOS, macOS, and Widget targets, sharing core logic via `Shared/`.
* **Companion:** Transcript-generation pipeline (Python using OpenAI Whisper in `Tools/`). Alignment is now entirely in-app via WhisperKit (on-device CoreML).
* **Stack:** Swift, SwiftUI, Python.
* **Current Phase:** Hardening the transcript/narration QA program (M1–M5): audio-only transcription reader, source-backed alignment, generated narration QA, pronunciation repair, and macOS parity.
* **Auto-Alignment:** A progressive alignment pipeline (`AutoAlignmentService`) that inserts alignment anchors automatically. Tier 0 (`ChapterTitleMatcher`) fuzzy-matches M4B chapter titles against EPUB headings (Levenshtein + word-level Jaccard) before any transcription — generic numeric track labels ("Chapter 7", "12") are skipped because m4b metadata numbers tracks, not book chapters, and contradicting numbers veto a match. Remaining chapters are content-aligned: audio is chunked at silences (VAD), transcribed with WhisperKit (on-device CoreML), and matched to EPUB tokens via dynamic time warping (`TokenDTW`). Each run clears its previous auto anchors so re-alignment converges. Progress + debug log shown in `AutoAlignmentProgressView`.
* **Transcript/Narration QA:** Audio-only books can materialize ASR into read-along text; source-backed books compare ASR against canonical EPUB/PDF text; generated narration can be re-transcribed for reviewable divergences; accepted pronunciation fixes persist overrides before re-render/re-QA.

## Architecture & Coding Guidelines
* **Separation of Concerns:** Keep Views clean and focused only on the UI. Use standard SwiftUI patterns (MVVM) and modern state management (`@Observable`, `@State`, `@Binding`, `@Environment`) to prevent memory leaks and unnecessary redraws.
* **Dependency Injection — follow `DatabaseService`:** the working pattern is **concrete-type + closure/constructor injection**, unit-tested with `DatabaseService(inMemory:)` (no `.shared`). Inject seams that way.
    * **History (2026-06-14, `CODE_AUDIT.md` §10.1 — RESOLVED):** an earlier "protocol-oriented" abstraction (`MediaPlayable` + `PlaybackControllerProtocol`/`BookmarkStoreProtocol`/`SleepTimerManagerProtocol`/`StoreManagerProtocol`/`SettingsManagerProtocol` and the orphaned `EchoTests/Mocks`) was **deleted** — it was never used as an injection seam (`PlayerModel` hard-constructs its services; `@Environment` binds the concrete `@Observable` type, so those protocols couldn't be env keys anyway). **Add a protocol back only when a real second implementation (e.g. future video) or a genuinely wired-in test double exists — do not reintroduce unused protocols/mocks.**
* **Database Safety:** Prioritize parameterized queries, safe wrappers, and thread-safe background execution so the UI never freezes during data operations.
* **Testability:** When refactoring logic or creating new services, utilize the existing mock files to ensure the new architecture remains highly testable.

## Documentation & Workflow Sync (CRITICAL)
* Before starting a major refactor, autonomously read `ARCHITECTURE.md` to understand the current blueprint.
* Whenever we add a feature, change the architecture, or modify the Python pipeline, **you must explicitly remind me** that the documentation needs updating, and proactively offer to update `README.md` or `ARCHITECTURE.md`.
* Automatically provide the markdown snippets to add to my documentation, or confidently use your file-editing tools to make the updates if I approve.

## Branching & Release Workflow (CRITICAL)
Echo ships on the standard promotion ladder — `feature/* → nightly → weekly → main` — and the authoritative branch/PR rules live in **AGENTS.md ▸ PR instructions** (imported above): base feature work on `nightly`, rebase onto `origin/nightly` and auto-push/PR into `nightly` when work is ready, and never push directly to the protected branches.

Echo specifics on top of those rules:
* CI (`Build gate + tests`) gates all three protected branches; scheduled `release-trains.yml` builds `nightly` daily and `weekly` Mondays to TestFlight.
* After opening or updating a PR, follow hosted CI with `gh pr checks`; if it fails, inspect the failing job logs first, fix the concrete blocker, push, and re-check until it is passing, pending for an external reason, or clearly blocked.
* Full detail lives in **ARCHITECTURE.md ▸ Release Engineering — Promotion Ladder**; read it before doing anything release- or branch-related.

## Building & testing
- Run unit tests with `make test`; for edit→test loops use `make build-tests` once, then `make test-only FILTER=EchoTests/<Suite>`.
- Build echo-cli with `make echo-cli` ONLY (pins Release + `SWIFT_COMPILATION_MODE=incremental` → `.build/cli/Build/Products/Release/echo-cli`). A bare `xcodebuild -scheme echo-cli` produces a Debug (-Onone) binary (scheme default is Debug) — ~26% slower on inference-bound narrate, far worse on Swift-heavy qa/deck/sidecar paths — and adding `-configuration Release` alone HANGS at first synthesize on macOS 26 (wholemodule miscompiles an async continuation) — see ARCHITECTURE.md ▸ Headless CLI export.
- Build concurrency is governed by the global memory-pressure RAM gate (`~/.claude/bin/xcode-build-gate.sh`); let it decide rather than serializing by hand, and never enable uncapped parallel testing or `-jobs`.
- UI tests are intentionally excluded from the Echo scheme's test action.
