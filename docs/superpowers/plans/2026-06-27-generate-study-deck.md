# Echo-Native Generate Study Deck Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first Echo-native "Generate Study Deck" slice for an already-imported EPUB/book, starting from persisted `epub_block` rows and ending with accepted `Flashcard` rows carrying `sourceBlockID`.

**Architecture:** Keep the first slice native to Echo: source DTOs are derived from `EPubBlockRecord`, fixture drafts are deterministic and reviewable, and accepted drafts are inserted through Echo persistence. Do not port EchoDeckBuilder's app shell, parser, prompt stack, or JSON import flow.

**Tech Stack:** Xcode project, Swift, SwiftUI, Observation, GRDB, Swift Testing.

## Global Constraints

- Start from Echo's existing persisted EPUB blocks, not Builder's parser.
- Do not embed EchoDeckBuilder wholesale or port Builder's SwiftUI shell.
- Do not use manual `targetMediaID` in the native Echo path.
- Do not make hosted/CLI AI part of the first slice.
- Do not commit private EPUB content or print private book text.
- Do not introduce third-party dependencies.
- Preserve this checkout's settings: Xcode 26.6, `SWIFT_VERSION = 6.0`, `SWIFT_STRICT_CONCURRENCY = complete`, MainActor default isolation, iOS deployment target 18.0, macOS deployment target 15.0, watchOS deployment target 11.0.
- Follow Echo's concrete-type plus closure/constructor injection style; do not add unused protocols.
- Do not run concurrent `xcodebuild` invocations.

---

### Task 1: Source DTOs From Persisted EPUB Blocks

**Files:**
- Create: `Shared/Services/StudyDeckGenerationTypes.swift`
- Create: `Shared/Services/StudyDeckSourceBuilder.swift`
- Create: `EchoTests/StudyDeckSourceBuilderTests.swift`

**Interfaces:**
- Produces: `StudyDeckSource`, `StudyDeckGenerationSelection`, `StudyDeckSourceBuilder.sources(audiobookID:selection:) throws -> [StudyDeckSource]`
- Consumes: `EPubBlockDAO`, `EPubBlockRecord`, `DatabaseWriter`

- [x] Add DTOs for generation source blocks and selection scope.
- [x] Add a builder that reads visible, non-front-matter text blocks in reading order.
- [x] Add tests for visible block filtering, current-block selection, chapter selection, text trimming, and `sourceBlockID` preservation.
- [x] Run `make build-tests`, then `make test-only FILTER=EchoTests/StudyDeckSourceBuilderTests`.

### Task 2: Fixture Draft Generator

**Files:**
- Modify: `Shared/Services/StudyDeckGenerationTypes.swift`
- Create: `Shared/Services/FixtureStudyDeckGenerator.swift`
- Create: `EchoTests/FixtureStudyDeckGeneratorTests.swift`

**Interfaces:**
- Produces: `GeneratedStudyDeckDraft`, `GeneratedStudyDeckCardDraft`, `FixtureStudyDeckGenerator.generate(sources:settings:) -> GeneratedStudyDeckDraft`
- Consumes: `StudyDeckSource`

- [x] Add draft/settings/result DTOs that retain `sourceBlockID`.
- [x] Generate deterministic front/back text without copying long source passages.
- [x] Add validation for non-empty text and source membership.
- [x] Run `make build-tests`, then `make test-only FILTER=EchoTests/FixtureStudyDeckGeneratorTests`.

### Task 3: Accept Drafts Into Echo Persistence

**Files:**
- Create: `Shared/Services/StudyDeckAcceptanceService.swift`
- Reuse: `Shared/Database/DAOs/FlashcardDAO.swift` existing `sourceBlockID` timeline sync
- Create: `EchoTests/StudyDeckAcceptanceServiceTests.swift`

**Interfaces:**
- Produces: `StudyDeckAcceptanceService.accept(_:audiobookID:bookTitle:selectedCardIDs:now:) throws -> [Flashcard]`
- Consumes: `GeneratedStudyDeckDraft`, `FlashcardDAO`

- [x] Insert selected accepted drafts directly into `flashcard`.
- [x] Preserve `Flashcard.sourceBlockID`, timestamps, tags, deck ID, and review defaults.
- [x] Reuse `FlashcardDAO` timeline sync that sets `TimelineItem.epubBlockID` when `sourceBlockID` exists.
- [x] Test accepted card insertion and timeline/reader placement prerequisites without private EPUB text.
- [x] Run `make build-tests`, then `make test-only FILTER=EchoTests/StudyDeckAcceptanceServiceTests`.

### Task 4: Minimal Review View Model And UI Entry

**Files:**
- Create: `EchoCore/ViewModels/StudyDeckGenerationViewModel.swift`
- Create: `EchoCore/Views/StudyDeckGenerationSheet.swift`
- Modify: `EchoCore/Views/BookSettingsView.swift`

**Interfaces:**
- Consumes: `StudyDeckSourceBuilder`, `FixtureStudyDeckGenerator`, `StudyDeckAcceptanceService`

- [x] Add a small `@MainActor @Observable` view model for load, draft selection, accept, and errors.
- [x] Add a minimal review/accept sheet from the existing book settings/study area.
- [x] Post an existing refresh notification after accepted cards are inserted if needed.
- [x] Run targeted view model tests if added, then `make test`.

### Task 5: Final Verification And Review

**Files:**
- No planned source changes.

- [x] Run targeted tests for all new suites.
- [x] Run `make test` when feasible.
- [x] Dispatch final code review subagent and fix Critical/Important findings.
