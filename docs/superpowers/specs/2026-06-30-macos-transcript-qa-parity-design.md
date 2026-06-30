# macOS DB-Native Transcript QA Parity — Design

**Date:** 2026-06-30
**Status:** Approved
**Author:** Dan Fakkeldy + Claude

## 1. Context

M1-M5 built a complete transcript QA pipeline: audio-only books open in the read-along reader after on-device transcription, source-backed books align ASR to canonical text, generated narration is QA'd for mispronunciations, and fixes flow through a repair loop. All shared services (`TranscriptMaterializer`, `SourceBackedAlignmentCoordinator`, `NarrationQADetector`, `NarrationQAService`, `PronunciationRepairService`) are pure `EchoCore/Services` and auto-bundle into macOS — but macOS has no UI to drive them.

This design adds macOS-native views and coordinators so macOS gets the same feature set as iOS, using the same shared engine.

## 2. Discovery

- `StandaloneTranscriptionService` has no `#if os(iOS)` guard — it already compiles for macOS with `@preconcurrency import WhisperKit`
- macOS uses a tri-pane layout: `MacTriPaneView` (Sidebar | Reader | Detail)
- The existing CLI-based transcription system (`TranscriptionManager`/`TranscriptStore`/`TranscriptPane`) is untouched — DB-native is additive
- `NarrationQAReviewModel.acceptFix` is already gated `#if os(iOS) || os(macOS)`

## 3. Components

### 3.1 MacTranscribeCoordinator

macOS equivalent of `TranscribeBookCoordinator`. Lives in `Echo macOS/Services/`.

```
@MainActor @Observable final class MacTranscribeCoordinator
    let service: StandaloneTranscriptionService
    private(set) var isFinalizing: Bool

    func transcribe(audiobookID:audioFileURL:chapters:resume:) async
    func finalize(audiobookID:) async          // materialize + set text_origin
    func clearTranscript(audiobookID:) async   // delegate to service
```

Same pattern as iOS: run WhisperKit → `TranscriptMaterializer.materialize` → `AudiobookDAO.save` with `textOrigin = "transcript"`.

### 3.2 MacTranscribeProgressView

macOS sheet shown during transcription. Lives in `Echo macOS/Views/`.

Mirrors `TranscribeProgressView` but uses macOS-native styling (`.frame(width:height:)` instead of the iOS `.frame(minWidth:idealWidth:)`). Shows chapter progress bar, Cancel/Done buttons.

### 3.3 MacNarrationQAReviewView

macOS window listing QA issues with source/heard text, issue type badge, and actions. Lives in `Echo macOS/Views/`.

Uses `NarrationQAReviewModel` (already cross-platform) as its data source. Each issue row shows: expected text, heard text, issue type, confidence. Actions: Ignore / Resolve / Save Override (acceptFix).

### 3.4 MacTriPaneView wiring

Add toolbar actions to the reader/content pane:

- **Transcribe** — shown when book is audio-only (`!model.hasEPUB && !model.hasPDF`). Opens `MacTranscribeProgressView` sheet.
- **Run Alignment** — shown when book has source text AND standalone transcript rows. Calls `SourceBackedAlignmentCoordinator.align()`.
- **Run QA** — shown after narration is generated. Calls `NarrationQAService.runQA()`.
- **Review Issues** — opens `MacNarrationQAReviewView` when QA issues exist.

## 4. Data flow

```
User clicks "Transcribe"
  → MacTranscribeCoordinator.transcribe()
    → StandaloneTranscriptionService.start()  (WhisperKit, on-device)
    → TranscriptMaterializer.materialize()    (DB projection)
    → AudiobookDAO.textOrigin = "transcript"
    → bumpDocumentIngestionTrigger()          (reader re-evaluates)
  → MacTranscribeProgressView updates live

User clicks "Run Alignment"
  → SourceBackedAlignmentCoordinator.align()
    → TokenDTW.alignWithBisection()
    → AnchorSelector.select()
    → AlignmentAnchorDAO.deleteAnchors(for:source:)  (clear prior)
    → AlignmentService.insertAnchors()               (persist)
    → WordTimingMaterializer.refine()                (DTW times)

User clicks "Run QA"
  → NarrationQAService.runQA()
    → WhisperSession re-transcribe audio
    → NarrationQADetector.detect()
    → DivergenceClassifier.classify()
    → NarrationQualityIssueDAO.insert()

User clicks "Save Override" on an issue
  → NarrationQAReviewModel.acceptFix()
    → PronunciationRepairService.applyFix()
      → PronunciationOverrideStore.set()  (per-book or global)
      → clear cached audio
      → re-render chapter
      → re-run QA
      → resolve issue
```

## 5. What this does NOT touch

- Existing CLI `TranscriptionManager` / `TranscriptStore` / `TranscriptPane`
- `MacBatchProcessingService` (already rewired for M4)
- `MacAlignmentService` (already exists, separate from source-backed alignment)
- `NarrationQAReviewModel` (already cross-platform, no changes needed)
- Any shared EchoCore services (they already work on macOS)

## 6. Testing

Each coordinator gets unit tests using `DatabaseService(inMemory:)` following the existing pattern. The progress view's `fraction(for:)` helper is testable as a pure function. Service-level tests already exist from M1-M5 and cover the shared engine.

## 7. Risks

- **WhisperKit on macOS**: `StandaloneTranscriptionService` imports WhisperKit — must verify it links and runs on macOS (WhisperKit supports macOS via SPM)
- **Memory**: WhisperKit models are large; transcription on macOS may contend with the 16GB limit
- **pbxproj**: New `Echo macOS/` files need Xcode target membership (the `PBXFileSystemSynchronizedRootGroup` may auto-include them)
