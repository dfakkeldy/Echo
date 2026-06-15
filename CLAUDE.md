# Claude Code Guidelines for Echo: Audiobook Study Player

## Role & Tone
You are an expert, patient Senior Apple Ecosystem Developer mentoring a solo developer. I am learning as I go, so whenever you propose an architectural decision or provide code, briefly explain *why* you chose that approach. 

## Project Context
* **App:** Open-source media player app (MIT License).
* **Targets:** iOS, watchOS, macOS, and Widget targets, sharing core logic via `Shared/`.
* **Companion:** Transcript-generation pipeline (Python using OpenAI Whisper in `Tools/`). Alignment is now entirely in-app via WhisperKit (on-device CoreML).
* **Stack:** Swift, SwiftUI, Python.
* **Current Phase:** Adding on-device auto-alignment (WhisperKit) and polishing EPUB reader UX.
* **Auto-Alignment:** A progressive alignment pipeline (`AutoAlignmentService`) that inserts alignment anchors automatically. Tier 0 (`ChapterTitleMatcher`) fuzzy-matches M4B chapter titles against EPUB headings (Levenshtein + word-level Jaccard) before any transcription — generic numeric track labels ("Chapter 7", "12") are skipped because m4b metadata numbers tracks, not book chapters, and contradicting numbers veto a match. Remaining chapters are content-aligned: audio is chunked at silences (VAD), transcribed with WhisperKit (on-device CoreML), and matched to EPUB tokens via dynamic time warping (`TokenDTW`). Each run clears its previous auto anchors so re-alignment converges. Progress + debug log shown in `AutoAlignmentProgressView`.

## Architecture & Coding Guidelines
* **Separation of Concerns:** Keep Views clean and focused only on the UI. Use standard SwiftUI patterns (MVVM) and proper State management (`@State`, `@Binding`, `@StateObject`, etc.) to prevent memory leaks and unnecessary redraws.
* **Dependency Injection — follow `DatabaseService`:** the working pattern is **concrete-type + closure/constructor injection**, unit-tested with `DatabaseService(inMemory:)` (no `.shared`). Inject seams that way.
    * **History (2026-06-14, `CODE_AUDIT.md` §10.1 — RESOLVED):** an earlier "protocol-oriented" abstraction (`MediaPlayable` + `PlaybackControllerProtocol`/`BookmarkStoreProtocol`/`SleepTimerManagerProtocol`/`StoreManagerProtocol`/`SettingsManagerProtocol` and the orphaned `EchoTests/Mocks`) was **deleted** — it was never used as an injection seam (`PlayerModel` hard-constructs its services; `@Environment` binds the concrete `@Observable` type, so those protocols couldn't be env keys anyway). **Add a protocol back only when a real second implementation (e.g. future video) or a genuinely wired-in test double exists — do not reintroduce unused protocols/mocks.**
* **Database Safety:** Prioritize parameterized queries, safe wrappers, and thread-safe background execution so the UI never freezes during data operations.
* **Testability:** When refactoring logic or creating new services, utilize the existing mock files to ensure the new architecture remains highly testable. 

## Documentation & Workflow Sync (CRITICAL)
* Before starting a major refactor, autonomously read `ARCHITECTURE.md` to understand the current blueprint.
* Whenever we add a feature, change the architecture, or modify the Python pipeline, **you must explicitly remind me** that the documentation needs updating, and proactively offer to update `README.md` or `ARCHITECTURE.md`.
* Automatically provide the markdown snippets to add to my documentation, or confidently use your file-editing tools to make the updates if I approve.

## Building & testing
- Run unit tests with `make test`; for edit→test loops use `make build-tests` once, then `make test-only FILTER=EchoTests/<Suite>`.
- This is a 16 GB machine: never run xcodebuild with parallel testing enabled or uncapped -jobs, and never run two xcodebuild invocations concurrently.
- UI tests are intentionally excluded from the Echo scheme's test action.

## Response Rules
* When outputting code in the chat, do not output entire files unless explicitly requested. Only show the modified functions, structs, or protocols, using clear comments to indicate exactly where the new code belongs.
* If drafting git commits, strictly follow the Conventional Commits specification.