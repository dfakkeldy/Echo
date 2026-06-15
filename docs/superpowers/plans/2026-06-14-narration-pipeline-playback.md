# Narration Pipeline Playback — iOS Migration & Robustness Implementation Plan

> **✅ COMPLETED 2026-06-14** via subagent-driven development (fresh implementer + spec + code-quality review per phase) on branch `claude/audit-phase7-api`, on top of WIP checkpoint `de31017`.
> Commits: `902f6bc` (A1–A4), `f3f3712` (A5), `b6c2c5e` (B1–B2), `5084c4e` (C1), `77c495b` (C2), `afa14fb` (C5), `78ac313` (C3), `8b09692` (C4), `3a27a62` (C6), plus two hardenings found in review: `c4a9b10` (at-gap render-ahead deadlock guard) and the "Preparing narration…" empty-plan clear.
> **17/17 narration + playlist tests green; final comprehensive review = READY TO MERGE.** Every build/edit/commit/test step below is done; the **on-device acceptance checklist remains unchecked — it needs Dan's iPhone** (no device available to the executor). Note: an unrelated concurrent process committed `f564077` (fastlane metadata) and `1d7632c` (ws8b docs) interleaved on this branch — not part of this plan.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make on-device EPUB narration play through Echo's main playback pipeline everywhere (not just CarPlay), fix the first-open race, and harden render scheduling, position restore, and the audio cache.

**Architecture:** `PlayerModel.startNarrationPlayback(voice:)` already renders narration chapters into `state.tracks` and plays them through the pipeline (so CarPlay / lock screen / scrubber work), with a pause-at-gap render-ahead. This plan (1) repoints the iPhone "Listen" UI at that single path and removes the divergent `BookDetailViewModel` `AVAudioPlayer`, (2) makes narration wait for the EPUB import before reading blocks, and (3) adds resume-on-reopen, bounded/pause-aware render-ahead, and a durable, self-evicting narration audio store.

**Tech Stack:** Swift, SwiftUI, GRDB, AVFoundation, Swift Testing. Kokoro TTS via FluidAudio (ANE).

**Pre-reading for the implementer:** `EchoCore/ViewModels/PlayerModel+Narration.swift` (the pipeline path), `CODE_AUDIT_NARRATION.md`, and the narration memory in this repo. Build/test on a 16 GB machine: **never run two `xcodebuild` invocations at once, never enable parallel testing.** Loop: `make build-tests` once, then `make test-only FILTER=EchoTests/<Suite>`.

---

## File Structure

**Created:**
- `EchoTests/NarrationFileNamingTests.swift` — unit tests for chapter-index parsing (Task C1).
- `EchoTests/NarrationCacheStoreTests.swift` — unit tests for stale-file selection (Task C5).

**Modified:**
- `EchoCore/Views/Narration/VoicePickerView.swift` — voice binding + `onStart` closure instead of `BookDetailViewModel` (Task A1).
- `EchoCore/Views/Narration/NarrationNudgeView.swift` — `onListen` closure instead of `BookDetailViewModel` (Task A2).
- `EchoCore/Views/NowPlayingTab.swift` — drive narration from `model` (Task A3).
- `EchoCore/ViewModels/PlayerModel+Narration.swift` — interim Now Playing, await import, resume, bounded render-ahead, evict stale files (Tasks A5, B2, C3, C4, C6).
- `EchoCore/Services/PlayerLoadingCoordinator.swift` — store the document-import `Task` (Task B1).
- `EchoCore/Services/Narration/NarrationFileNaming.swift` — `chapterIndex(fromFileName:)` (Task C1); add `NarrationCacheStore` here or in a new file (Task C5).
- `EchoCore/Services/Narration/NarrationChapterPlanner.swift` — `resume(_:startingAtChapterIndex:)` (Task C2, has a test in the existing `NarrationChapterPlannerTests.swift`).

**Deleted:**
- `EchoCore/ViewModels/BookDetailViewModel.swift` — redundant once the UI uses the pipeline (Task A4).

---

## Phase A — Unify the iPhone "Listen" UI on the pipeline

Today the nudge builds a `BookDetailViewModel` that renders chapter 0 to `temporaryDirectory` and plays it via a private `AVAudioPlayer`, bypassing the pipeline (review finding NARR-2). After this phase the iPhone uses exactly the same `startNarrationPlayback` path as CarPlay.

### Task A1: VoicePickerView takes a voice binding + start closure

**Files:**
- Modify: `EchoCore/Views/Narration/VoicePickerView.swift`

- [x] **Step 1: Replace the view model dependency with a binding + closure**

```swift
import SwiftUI

struct VoicePickerView: View {
    @Binding var selectedVoice: NarrationVoice
    let onStart: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(VoiceCatalog.all) { voice in
                Button {
                    selectedVoice = voice
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(voice.displayName).font(.headline)
                            Text(voice.descriptor)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selectedVoice.id == voice.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(selectedVoice.id == voice.id ? [.isSelected] : [])
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Choose a Voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start Narration") {
                        onStart()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
```

- [x] **Step 2: Build (it will fail until A3 updates the call site)**

Run: `make build-tests 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: errors in `NowPlayingTab.swift` / `NarrationNudgeView.swift` referencing the old `VoicePickerView(viewModel:)`. That's expected — A2 and A3 fix the callers. Do not commit yet.

### Task A2: NarrationNudgeView takes an onListen closure

**Files:**
- Modify: `EchoCore/Views/Narration/NarrationNudgeView.swift`

- [x] **Step 1: Replace the view model dependency with a closure**

```swift
import SwiftUI

struct NarrationNudgeView: View {
    let onListen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "headphones")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("No audiobook for this one")
                        .font(.headline)
                    Text("Echo can narrate it on-device so you can study hands-free.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)

            Button {
                onListen()
            } label: {
                Text("Listen \u{25B8}")
                    .bold()
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(.rect(cornerRadius: 12))
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(.rect(cornerRadius: 16))
    }
}
```

Note: the voice-picker `.sheet` and TTS pre-warm move to `NowPlayingTab` (Task A3).

### Task A3: NowPlayingTab drives narration from the model

**Files:**
- Modify: `EchoCore/Views/NowPlayingTab.swift`

- [x] **Step 1: Replace the `narrationVM` state with voice/picker state**

Find:

```swift
    @State private var narrationVM: BookDetailViewModel?
```

Replace with:

```swift
    @State private var selectedVoice: NarrationVoice = VoiceCatalog.default
    @State private var showingVoicePicker = false
```

- [x] **Step 2: Bind the narration UI block to the model's pipeline state**

Find the block that begins `if model.hasEPUB, let narrationVM {` and replace the whole `if` block with:

```swift
                // C2. On-device narration — shown when the book has EPUB text.
                if model.hasEPUB {
                    VStack(spacing: 8) {
                        NarrationStatusView(state: model.narrationPlaybackState)
                        if !model.narrationPlaybackState.isRunning {
                            NarrationNudgeView(onListen: { showingVoicePicker = true })
                        }
                    }
                    .padding(.horizontal, NowPlayingLayout.horizontalPadding)
                    .padding(.top, 12)
                }
```

- [x] **Step 3: Replace the `.task(id:)` that built the view model with a TTS pre-warm**

Find:

```swift
        .task(id: model.folderURL) {
            if let writer = model.databaseService?.writer, let id = model.folderURL?.absoluteString
            {
                narrationVM = BookDetailViewModel(
                    db: writer, audiobookID: id, audioEngine: model.audioEngine)
            } else {
                narrationVM = nil
            }
        }
```

Replace with:

```swift
        .task(id: model.folderURL) {
            // Pre-warm the ANE model compile so the first Listen tap isn't a long stall.
            if model.hasEPUB { try? await model.narrationTTS.prepare() }
        }
        .sheet(isPresented: $showingVoicePicker) {
            VoicePickerView(selectedVoice: $selectedVoice) {
                model.startNarrationPlayback(voice: selectedVoice)
            }
        }
```

- [x] **Step 4: Build**

Run: `make build-tests 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: the only remaining error references `BookDetailViewModel` (still on disk). Proceed to A4.

### Task A4: Delete the redundant BookDetailViewModel

**Files:**
- Delete: `EchoCore/ViewModels/BookDetailViewModel.swift`

- [x] **Step 1: Confirm nothing else references it**

Run: `grep -rn "BookDetailViewModel" --include="*.swift" EchoCore EchoTests | grep -v "/.claude/worktrees/"`
Expected: no matches outside the file itself. (Its export TODOs call `NarrationExportService` directly; Plan 5 will re-add export wiring there. If a match appears, stop and reconcile before deleting.)

- [x] **Step 2: Delete the file**

Run: `rm EchoCore/ViewModels/BookDetailViewModel.swift`

- [x] **Step 3: Build (now green)**

Run: `make build-tests 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `** TEST BUILD SUCCEEDED **`

- [x] **Step 4: Run the narration suites**

Run: `make test-only FILTER=EchoTests/NarrationServiceTests` then `make test-only FILTER=EchoTests/NarrationChapterPlannerTests`
Expected: both suites pass.

- [x] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor(narration): drive iPhone Listen UI through the playback pipeline; remove standalone AVAudioPlayer path"
```

### Task A5: Interim "Preparing narration…" Now Playing

While the first chapter renders (ANE compile + synthesis), Now Playing currently shows the audio-less placeholder "No .mp3/.m4a/.m4b files found" (review finding NARR-5). Show the book instead.

**Files:**
- Modify: `EchoCore/ViewModels/PlayerModel+Narration.swift`

- [x] **Step 1: Set an interim title + push Now Playing before rendering**

In `startNarrationPlayback`, immediately after `state.awaitingNarrationChapter = false` (the synchronous flag setup, before `let cacheDirectory = ...`), add:

```swift
        // Show the book + a preparing status on Now Playing / lock screen while
        // the first chapter renders, instead of the audio-less placeholder.
        if let title = folderURL?.deletingPathExtension().lastPathComponent {
            state.currentTitle = title
        }
        state.currentSubtitle = String(localized: "Preparing narration…")
        progressPresenter.updateNowPlayingInfo(isPaused: true)
```

- [x] **Step 2: Build + verify on device**

Run: `make build-tests 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `** TEST BUILD SUCCEEDED **`. On device: tapping Listen shows the book title + "Preparing narration…" on the lock screen during the first render, then the chapter title once playback starts.

- [x] **Step 3: Commit**

```bash
git add EchoCore/ViewModels/PlayerModel+Narration.swift
git commit -m "feat(narration): show 'Preparing narration…' on Now Playing during first render"
```

---

## Phase B — Fix the first-open race

On a book never opened on the phone, `loadFolder` schedules the EPUB import in a detached `Task` and returns; `startNarrationPlayback` then reads blocks immediately and finds none, so it silently no-ops (review finding NARR-3). Make narration await the import.

### Task B1: Store the document-import task on the coordinator

**Files:**
- Modify: `EchoCore/Services/PlayerLoadingCoordinator.swift`

- [x] **Step 1: Add a stored handle for the in-flight import**

Near the other coordinator properties (next to `var timelinePersistence: PlayerTimelinePersistenceService?`), add:

```swift
    /// The in-flight no-audio document import (EPUB blocks). `startNarrationPlayback`
    /// awaits this so a freshly opened book isn't read before its blocks exist.
    @ObservationIgnored var documentImportTask: Task<Void, Never>?
```

- [x] **Step 2: Assign the task in `importDocumentForAudiolessBook`**

Find:

```swift
        let importedEPUBFile = !isDirectory && pickedURL.pathExtension.lowercased() == "epub"
        Task { @MainActor in
```

Replace the `Task { @MainActor in` line with:

```swift
        let importedEPUBFile = !isDirectory && pickedURL.pathExtension.lowercased() == "epub"
        documentImportTask = Task { @MainActor in
```

- [x] **Step 3: Build**

Run: `make build-tests 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `** TEST BUILD SUCCEEDED **`

### Task B2: Narration awaits the import before reading blocks

**Files:**
- Modify: `EchoCore/ViewModels/PlayerModel+Narration.swift`

- [x] **Step 1: Await the import at the top of the render task**

In `startNarrationPlayback`, inside `narrationRenderTask = Task { ... }`, find:

```swift
            do {
                // visibleBlocks (not blocks) so blocks the user marked "Not in
                // Audio" in the reader are excluded from narration, matching the
                // alignment/timeline paths.
                let blocks = try EPubBlockDAO(db: db).visibleBlocks(for: audiobookID)
```

Insert the await immediately after `do {`:

```swift
            do {
                // Wait for loadFolder's no-audio EPUB import to finish so a
                // first-ever open isn't read before its blocks are committed.
                await self.playerLoadingCoordinator.documentImportTask?.value
                // visibleBlocks (not blocks) so blocks the user marked "Not in
                // Audio" in the reader are excluded from narration, matching the
                // alignment/timeline paths.
                let blocks = try EPubBlockDAO(db: db).visibleBlocks(for: audiobookID)
```

- [x] **Step 2: Build + verify**

Run: `make build-tests 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `** TEST BUILD SUCCEEDED **`. On device: import a brand-new EPUB and immediately trigger narration — it should render and play rather than silently doing nothing.

- [x] **Step 3: Commit**

```bash
git add EchoCore/Services/PlayerLoadingCoordinator.swift EchoCore/ViewModels/PlayerModel+Narration.swift
git commit -m "fix(narration): await EPUB import before reading blocks (first-open race)"
```

---

## Phase C — Robustness: resume, bounded render-ahead, durable cache

### Task C1: Parse chapter index from a narration file name

**Files:**
- Modify: `EchoCore/Services/Narration/NarrationFileNaming.swift`
- Test: `EchoTests/NarrationFileNamingTests.swift`

- [x] **Step 1: Write the failing test**

```swift
import Foundation
import Testing

@testable import Echo

@Suite struct NarrationFileNamingTests {
    @Test func parsesChapterIndexFromFileName() {
        // Format: "{safeID}-ch{N}-{voice}.m4a" — safeID has no '-' (safeToken maps
        // non-alphanumerics to '_'), so "-ch" only marks the chapter separator.
        #expect(NarrationFileNaming.chapterIndex(fromFileName: "book_id-ch0-af_heart.m4a") == 0)
        #expect(NarrationFileNaming.chapterIndex(fromFileName: "x_y-ch12-bf_emma.m4a") == 12)
    }

    @Test func returnsNilForNonNarrationFileName() {
        #expect(NarrationFileNaming.chapterIndex(fromFileName: "cover.jpg") == nil)
        #expect(NarrationFileNaming.chapterIndex(fromFileName: "book-noch-af_heart.m4a") == nil)
    }
}
```

- [x] **Step 2: Run it to verify it fails**

Run: `make build-tests 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: FAIL — "type 'NarrationFileNaming' has no member 'chapterIndex'".

- [x] **Step 3: Implement the parser**

Add inside `enum NarrationFileNaming`:

```swift
    /// Recovers the chapter index from a name produced by `chapterFileName`,
    /// or `nil` if the name isn't a narration chapter file. Used to resume at the
    /// last-played chapter on reopen.
    static func chapterIndex(fromFileName fileName: String) -> Int? {
        guard let marker = fileName.range(of: "-ch") else { return nil }
        let digits = fileName[marker.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }
```

- [x] **Step 4: Run the test**

Run: `make build-tests` then `make test-only FILTER=EchoTests/NarrationFileNamingTests`
Expected: both tests pass.

- [x] **Step 5: Commit**

```bash
git add EchoCore/Services/Narration/NarrationFileNaming.swift EchoTests/NarrationFileNamingTests.swift
git commit -m "feat(narration): parse chapter index from rendered file name"
```

### Task C2: Reorder the chapter plan to resume at a chapter

**Files:**
- Modify: `EchoCore/Services/Narration/NarrationChapterPlanner.swift`
- Test: `EchoTests/NarrationChapterPlannerTests.swift` (existing)

- [x] **Step 1: Add the failing test to the existing suite**

Append inside `struct NarrationChapterPlannerTests`:

```swift
    @Test func resumeStartsAtChapterThenForwardOnly() {
        let plan = [0, 1, 2, 3].map {
            NarrationChapterPlanner.PlannedChapter(
                index: $0, blocks: [block(id: "b\($0)", chapter: $0, text: "t", seq: 0)])
        }
        #expect(NarrationChapterPlanner.resume(plan, startingAtChapterIndex: 2).map(\.index) == [2, 3])
        // Unknown index → full plan from the start.
        #expect(NarrationChapterPlanner.resume(plan, startingAtChapterIndex: 99).map(\.index) == [0, 1, 2, 3])
    }
```

- [x] **Step 2: Run it to verify it fails**

Run: `make build-tests 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: FAIL — "type 'NarrationChapterPlanner' has no member 'resume'".

- [x] **Step 3: Implement `resume`**

Add inside `enum NarrationChapterPlanner`:

```swift
    /// Reorders a plan to begin at `resumeIndex` (forward-only). Earlier chapters
    /// are dropped from the queue — going back before the resume point re-narrates
    /// from scratch, which is acceptable for v1. Unknown index → unchanged plan.
    static func resume(_ chapters: [PlannedChapter], startingAtChapterIndex resumeIndex: Int)
        -> [PlannedChapter]
    {
        guard let pos = chapters.firstIndex(where: { $0.index == resumeIndex }) else {
            return chapters
        }
        return Array(chapters[pos...])
    }
```

- [x] **Step 4: Run the suite**

Run: `make build-tests` then `make test-only FILTER=EchoTests/NarrationChapterPlannerTests`
Expected: all pass.

- [x] **Step 5: Commit**

```bash
git add EchoCore/Services/Narration/NarrationChapterPlanner.swift EchoTests/NarrationChapterPlannerTests.swift
git commit -m "feat(narration): resume chapter plan at a given chapter index"
```

### Task C3: Resume at the last-played chapter on reopen

The pipeline already persists the last track (`saveLastTrack` in `configureTrackState`) and the within-chapter position (`saveBookProgress`, restored by `onDurationLoaded`). A narration `Track.id` is its file URL, which is deterministic per chapter+voice — so starting playback at the saved chapter lets the existing position-restore seek fire automatically.

**Files:**
- Modify: `EchoCore/ViewModels/PlayerModel+Narration.swift`

- [x] **Step 1: Resume the plan from the saved chapter**

In `startNarrationPlayback`'s render task, find:

```swift
                let chapters = NarrationChapterPlanner.plan(from: blocks)
                guard !chapters.isEmpty else {
                    self.state.narrationRenderInFlight = false
                    return
                }
```

Replace with:

```swift
                let plan = NarrationChapterPlanner.plan(from: blocks)
                guard !plan.isEmpty else {
                    self.state.narrationRenderInFlight = false
                    return
                }
                // Resume at the last-played chapter (forward-only). The pipeline's
                // own position-restore seeks within that chapter, because the
                // narration Track.id is the deterministic per-chapter file URL.
                let chapters: [NarrationChapterPlanner.PlannedChapter]
                if let lastTrackID = self.persistence.getLastTrack(for: audiobookID),
                    let fileName = URL(string: lastTrackID)?.lastPathComponent,
                    let resumeIndex = NarrationFileNaming.chapterIndex(fromFileName: fileName)
                {
                    chapters = NarrationChapterPlanner.resume(plan, startingAtChapterIndex: resumeIndex)
                } else {
                    chapters = plan
                }
```

(No other edit needed — the existing `for (offset, chapter) in chapters.enumerated()` loop now iterates the resumed plan.)

- [x] **Step 2: Build + verify on device**

Run: `make build-tests 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `** TEST BUILD SUCCEEDED **`. On device: play a narration book to chapter 3, close and reopen the app, retrigger narration — it should resume at chapter 3 near where you left off rather than chapter 1.

Note: `self.persistence` is `PlayerModel`'s injected `Persistence` (the same instance wired into `playerLoadingCoordinator.persistence`). If the property is named differently, use the model's existing `Persistence` reference.

- [x] **Step 3: Commit**

```bash
git add EchoCore/ViewModels/PlayerModel+Narration.swift
git commit -m "feat(narration): resume at last-played chapter on reopen"
```

### Task C4: Bound render-ahead and pause it while playback is paused

The render loop currently synthesizes every remaining chapter back-to-back, even while paused (review finding NARR-6). Bound it to a small look-ahead and gate on playback.

**Files:**
- Modify: `EchoCore/ViewModels/PlayerModel+Narration.swift`

- [x] **Step 1: Gate each render past the first on playback progress**

In `startNarrationPlayback`'s loop, find:

```swift
                for (offset, chapter) in chapters.enumerated() {
                    try Task.checkCancellation()
                    try await service.renderChapter(
                        chapterIndex: chapter.index, blocks: chapter.blocks, voice: voice.id)
```

Replace with:

```swift
                let lookAhead = 2
                for (offset, chapter) in chapters.enumerated() {
                    try Task.checkCancellation()
                    // Render-ahead backpressure: don't synthesize more than
                    // `lookAhead` chapters past the one currently playing, and
                    // don't render while paused. (offset 0 always renders first.)
                    while offset > 0,
                        self.folderURL?.absoluteString == audiobookID,
                        self.state.currentIndex + lookAhead < offset || !self.isPlaying
                    {
                        try await Task.sleep(for: .seconds(1))
                        try Task.checkCancellation()
                    }
                    guard self.folderURL?.absoluteString == audiobookID else { return }
                    try await service.renderChapter(
                        chapterIndex: chapter.index, blocks: chapter.blocks, voice: voice.id)
```

- [x] **Step 2: Build + verify on device**

Run: `make build-tests 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `** TEST BUILD SUCCEEDED **`. On device: while a narration book plays, confirm only ~2 chapters render ahead (watch CPU/thermals settle), and that pausing playback stops further synthesis until you resume.

Note: `self.isPlaying` is `PlayerModel`'s existing playing flag (`state.isPlaying`). The look-ahead is intentionally small; the pause-at-gap fix already handles the case where playback outruns rendering.

- [x] **Step 3: Commit**

```bash
git add EchoCore/ViewModels/PlayerModel+Narration.swift
git commit -m "perf(narration): bound render-ahead and pause synthesis while paused"
```

### Task C5: Select stale narration files for eviction

**Files:**
- Modify: `EchoCore/Services/Narration/NarrationFileNaming.swift` (add `NarrationCacheStore`)
- Test: `EchoTests/NarrationCacheStoreTests.swift`

- [x] **Step 1: Write the failing test**

```swift
import Foundation
import Testing

@testable import Echo

@Suite struct NarrationCacheStoreTests {
    @Test func selectsThisBooksOtherVoiceFilesForEviction() {
        // bookPrefix matches NarrationFileNaming.chapterPrefix == "{safeID}-ch".
        let files = [
            "book-ch0-af_heart.m4a",  // current voice — keep
            "book-ch1-af_heart.m4a",  // current voice — keep
            "book-ch0-bf_emma.m4a",  // same book, stale voice — evict
            "other-ch0-af_heart.m4a",  // different book — leave alone
        ]
        let stale = NarrationCacheStore.staleVoiceFiles(
            files, bookPrefix: "book-ch", currentVoice: VoiceID("af_heart"))
        #expect(stale == ["book-ch0-bf_emma.m4a"])
    }
}
```

- [x] **Step 2: Run it to verify it fails**

Run: `make build-tests 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: FAIL — "cannot find 'NarrationCacheStore' in scope".

- [x] **Step 3: Implement the selector**

Add to `NarrationFileNaming.swift` (below the `NarrationFileNaming` enum):

```swift
/// Pure helpers for keeping the rendered-narration directory tidy.
enum NarrationCacheStore {
    /// File names belonging to `bookPrefix` rendered with a voice other than
    /// `currentVoice` — safe to delete when (re)rendering with the new voice.
    static func staleVoiceFiles(
        _ fileNames: [String], bookPrefix: String, currentVoice: VoiceID
    ) -> [String] {
        let keepSuffix = "-\(currentVoice.rawValue).m4a"
        return fileNames.filter { $0.hasPrefix(bookPrefix) && !$0.hasSuffix(keepSuffix) }
    }
}
```

- [x] **Step 4: Run the test**

Run: `make build-tests` then `make test-only FILTER=EchoTests/NarrationCacheStoreTests`
Expected: pass.

- [x] **Step 5: Commit**

```bash
git add EchoCore/Services/Narration/NarrationFileNaming.swift EchoTests/NarrationCacheStoreTests.swift
git commit -m "feat(narration): select stale-voice cache files for eviction"
```

### Task C6: Durable narration store + evict stale files on start

Move rendered audio out of `Caches` (OS-purgeable mid-play) into `Application Support`, exclude it from backup, and evict stale-voice files when narration starts.

**Files:**
- Modify: `EchoCore/ViewModels/PlayerModel+Narration.swift`

- [x] **Step 1: Point the store at Application Support and exclude it from backup**

Replace the existing `narrationCacheDirectory()` helper with:

```swift
    /// App-owned, durable location for rendered narration audio. Application
    /// Support (not Caches) so iOS won't purge a queued chapter mid-play, and it's
    /// excluded from iCloud/iTunes backup since it's regenerable.
    static func narrationCacheDirectory() -> URL {
        let fm = FileManager.default
        var base = (fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory)
            .appendingPathComponent("Narration", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? base.setResourceValues(values)
        return base
    }
```

- [x] **Step 2: Evict stale-voice files when narration starts**

In `startNarrationPlayback`, after `let cacheDirectory = Self.narrationCacheDirectory()` and before constructing the `NarrationService`, add:

```swift
        // Drop this book's files rendered with a previous voice so the store
        // doesn't grow unbounded across voice changes.
        let bookPrefix = NarrationFileNaming.chapterPrefix(audiobookID: audiobookID)
        if let names = try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path) {
            for stale in NarrationCacheStore.staleVoiceFiles(
                names, bookPrefix: bookPrefix, currentVoice: voice.id)
            {
                try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(stale))
            }
        }
```

- [x] **Step 3: Build + run narration suites**

Run: `make build-tests 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `** TEST BUILD SUCCEEDED **`. Then `make test-only FILTER=EchoTests/NarrationCacheStoreTests` and `make test-only FILTER=EchoTests/NarrationChapterPlannerTests` — both pass.

- [x] **Step 4: Verify on device**

Render narration with voice A, switch to voice B and re-trigger: voice-A files for that book are gone, playback uses voice B, and a screen-locked drive no longer loses a queued chapter to a cache purge.

- [x] **Step 5: Commit**

```bash
git add EchoCore/ViewModels/PlayerModel+Narration.swift
git commit -m "feat(narration): durable Application Support store + stale-voice eviction"
```

---

## Final verification

- [x] **Full narration suite sweep**

Run, one at a time:
```
make build-tests
make test-only FILTER=EchoTests/NarrationServiceTests
make test-only FILTER=EchoTests/NarrationChapterPlannerTests
make test-only FILTER=EchoTests/NarrationFileNamingTests
make test-only FILTER=EchoTests/NarrationCacheStoreTests
make test-only FILTER=EchoTests/AudiolessEPUBImportTests
make test-only FILTER=EchoTests/PlaylistManagerTests
```
Expected: all pass.

- [ ] **On-device acceptance (iPhone, primary surface):**
  1. Open a standalone EPUB → tap **Listen** → pick a voice → narration plays through the normal player (lock screen transport, scrubber, Now Playing title = "Chapter 1").
  2. Let chapter 1 finish before chapter 2 renders → playback **pauses and resumes** into chapter 2, never restarts chapter 1.
  3. Hide a paragraph ("Not in Audio") → it is not spoken.
  4. Reopen mid-book → narration resumes near where you left off.
  5. Switch voice → old-voice files are gone, playback uses the new voice.

- [x] **Docs:** Update the narration memory and `CODE_AUDIT_NARRATION.md` to note the pipeline-playback path is now the single narration route (CarPlay + iPhone), and remove the "iOS path divergent" caveat.

---

## Notes & deferred

- **CarPlay** is covered by this same `startNarrationPlayback` path (already wired). The plan owner has no CarPlay; CarPlay acceptance happens via TestFlight.
- **Forward-only resume** (Task C2/C3): going back before the resume point re-narrates. A full bidirectional queue is a future enhancement.
- **Whole-book disk cap / LRU across books** is out of scope; Task C6 only evicts stale-voice files for the current book. A global size cap can come later.
- **Export** (`exportM4B`/`exportChapters`, formerly on `BookDetailViewModel`): re-add as a thin call into `NarrationExportService` when Plan 5 wires the export UI.
