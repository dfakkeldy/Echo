# Narration Status Visibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make iOS narration observable from explicit start through model delivery, concurrent rendering/playback, queue waits, completion, cancellation, and failure, with a persistent expandable card, lock-screen summaries, and privacy-safe unified logs.

**Architecture:** Extend the existing main-actor `NarrationState` into the single observable session store, but represent rendering, playback, and playable-buffer state independently. Feed it structured progress at the existing ONNX, narration-service, render-loop, and playback-controller boundaries; derive all card and lock-screen copy through one pure formatter. Keep the SwiftUI view passive and mount the same component in both iOS player layouts.

**Tech Stack:** Swift 6, Observation, SwiftUI, OSLog, AVFoundation playback coordination, ONNX Runtime model preparation, Swift Testing, Xcode 26 iOS Simulator.

## Global Constraints

- Preserve deployment floors exactly: iOS 18, macOS 15, and watchOS 11.
- Preserve Swift 6 concurrency and the app targets' default Main Actor isolation.
- Keep model download, ONNX session creation, synthesis, file I/O, and database work off the UI actor; only observable state mutation belongs on the main actor.
- Do not add a protocol, service, third-party dependency, schema migration, or persistence layer for this feature.
- Do not change synthesis quality, render-ahead depth (`lookAhead == 2`), cache identity, audio files, or queue ordering.
- Voice packs are bundled. User-visible copy must say a voice is selected or loaded, never downloaded.
- Never put book text, title, author, pronunciation content, or local paths in unified logs.
- Keep only the latest 200 in-app events for the current narration session; reset them on a new session or book switch, not on pause/completion/failure.
- Download event history advances in five-percentage-point milestones while the live progress value may update more often.
- Remove the silent Now Playing model prewarm. Model preparation starts only after an explicit narration request creates a visible session.
- Localize every new user-facing string and preserve Dynamic Type, VoiceOver, reduced-motion, and contrast behavior.
- Run every Apple build/test command as one complete command through `/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- <command>`.
- Branch workflow remains `codex/narration-status-verbosity -> nightly`; do not push directly to `nightly`, `weekly`, or `main`.

## File Map

- Create `EchoCore/Services/Narration/NarrationStatusTypes.swift`: immutable render, playback, buffer, event, and snapshot value types shared by state, formatter, service callbacks, and tests.
- Modify `EchoCore/Services/Narration/NarrationState.swift`: observable session ownership, bounded events, milestone coalescing, OSLog emission, transition methods, and compatibility projections.
- Create `EchoCore/Services/Narration/NarrationStatusPresentation.swift`: pure precedence and copy formatting for the card, accessibility, and lock screen.
- Modify `EchoCore/Services/Narration/TTSEngine.swift`: exact model-delivery progress contract and headless/batch progress mapping.
- Modify `EchoCore/Services/Narration/ProgressFanOut.swift`: replay the latest preparation state to late joiners.
- Modify `EchoCore/Services/Narration/OnnxKokoroEngine.swift`: cache-check, byte delivery, validation, session-load, and ready signals.
- Modify `EchoCore/Services/Narration/HeadlessNarrationRunner.swift`: preserve monotonic command-line preparation progress with the expanded enum.
- Modify `EchoCore/Services/Narration/NarrationService.swift`: structured block progress and rendered-segment result delivery.
- Modify `EchoCore/ViewModels/PlayerModel+Narration.swift`: create sessions, reject stale callbacks, update concurrent lifecycle dimensions, buffer counts, events, and lock-screen publication.
- Modify `EchoCore/Services/PlaybackController.swift`: distinguish ordinary pause, narration queue wait, and natural end.
- Modify `EchoCore/ViewModels/PlayerModel.swift`: consume typed playback changes, clear/cancel sessions correctly, and provide operational lock-screen subtitles.
- Modify `EchoCore/Views/Narration/NarrationStatusView.swift`: persistent compact card plus expandable event history.
- Modify `EchoCore/Views/NowPlayingTab.swift`: remove silent prewarm and retain the card in the standard layout.
- Modify `EchoCore/Views/Player/ExperimentalNowPlayingView.swift`: mount the same card in the experimental layout.
- Delete `EchoCore/Services/Narration/NarrationProgressText.swift` and `EchoTests/NarrationProgressTextTests.swift` after the shared formatter replaces their only production use.
- Modify existing narration, playback, player-model, and layout test files; create focused status-type and presentation suites.
- Do not edit `Echo.xcodeproj/project.pbxproj`; the project uses synchronized filesystem groups for Swift sources/tests.

---

### Task 1: Observable Narration Session and Event History

**Files:**
- Create: `EchoCore/Services/Narration/NarrationStatusTypes.swift`
- Modify: `EchoCore/Services/Narration/NarrationState.swift`
- Create: `EchoTests/NarrationStatusTypesTests.swift`
- Modify: `EchoTests/NarrationStateTests.swift`

**Interfaces:**
- Produces: `NarrationRenderUnitStatus`, `NarrationRenderActivity`, `NarrationPlaybackActivity`, `NarrationBufferStatus`, `NarrationEventDescriptor`, `NarrationEvent`, `NarrationStatusSnapshot`, and `NarrationRenderProgress`.
- Produces: `NarrationState.beginSession(defaultVoiceID:at:)`, `transitionRender(to:event:at:)`, `transitionPlayback(to:event:at:)`, `updateBuffer(_:)`, `reportModelDownload(receivedBytes:totalBytes:at:) -> Bool`, `record(_:at:)`, and `reset()`.
- Preserves temporarily: the existing `Phase`, `progress`, `statusMessage`, `update`, `fail`, and `complete` compatibility surface so intermediate commits build. Task 8 removes stored legacy mutation after every caller migrates.

- [ ] **Step 1: Write failing value-type and state tests**

Add cases that prove independent activity dimensions, event retention, and milestone coalescing:

```swift
@MainActor
@Suite struct NarrationStatusTypesTests {
    @Test func playingAndRenderingRemainIndependent() {
        let state = NarrationState()
        let now = Date(timeIntervalSince1970: 100)
        state.beginSession(defaultVoiceID: VoiceID("af_heart"), at: now)
        state.transitionPlayback(
            to: .playing(chapterDisplayNumber: 2),
            event: .init(
                category: .playback, severity: .notice,
                message: "Playing chapter 2",
                developerMessage: "playback playing chapter=2"),
            at: now)
        state.transitionRender(
            to: .rendering(
                NarrationRenderUnitStatus(
                    chapterDisplayNumber: 4, segmentIndex: 0,
                    voiceID: VoiceID("af_heart"), completedBlocks: 8,
                    totalBlocks: 19, startedAt: now, lastProgressAt: now)),
            event: nil, at: now)

        #expect(state.snapshot.playback == .playing(chapterDisplayNumber: 2))
        guard case .rendering(let unit) = state.snapshot.render else {
            Issue.record("Expected rendering activity")
            return
        }
        #expect(unit.completedBlocks == 8)
        #expect(unit.totalBlocks == 19)
    }

    @Test func eventHistoryKeepsLatestTwoHundred() {
        let state = NarrationState()
        state.beginSession(defaultVoiceID: VoiceID("af_heart"))
        for index in 0..<205 {
            state.record(
                .init(
                    category: .render, severity: .info,
                    message: "Block \(index)",
                    developerMessage: "render block=\(index)"))
        }
        #expect(state.events.count == 200)
        #expect(state.events.first?.message == "Block 5")
        #expect(state.events.last?.message == "Block 204")
    }

    @Test func downloadHistoryUsesFivePercentMilestones() {
        let state = NarrationState()
        state.beginSession(defaultVoiceID: VoiceID("af_heart"))
        #expect(state.reportModelDownload(receivedBytes: 1, totalBytes: 100))
        #expect(!state.reportModelDownload(receivedBytes: 4, totalBytes: 100))
        #expect(state.reportModelDownload(receivedBytes: 5, totalBytes: 100))
        #expect(!state.reportModelDownload(receivedBytes: 9, totalBytes: 100))
        #expect(state.reportModelDownload(receivedBytes: 10, totalBytes: 100))
        #expect(state.events.filter { $0.category == .model }.count == 3)
    }
}
```

Update `NarrationStateTests` to assert that `reset()` clears `snapshot`, events, selected voice, and download milestone state, while `isRunning` derives from active preparation/rendering work.

- [ ] **Step 2: Run the focused build to verify RED**

Run:

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
```

Expected: build fails because `NarrationStatusSnapshot`, transition methods, and the new activity types do not exist.

- [ ] **Step 3: Add the immutable lifecycle types**

Create this exact surface in `NarrationStatusTypes.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated struct NarrationRenderUnitStatus: Equatable, Sendable {
    let chapterDisplayNumber: Int
    let segmentIndex: Int?
    let voiceID: VoiceID
    let completedBlocks: Int
    let totalBlocks: Int
    let startedAt: Date
    let lastProgressAt: Date

    var fraction: Double {
        guard totalBlocks > 0 else { return 0 }
        return min(1, max(0, Double(completedBlocks) / Double(totalBlocks)))
    }
}

nonisolated enum NarrationRenderActivity: Equatable, Sendable {
    case idle
    case planning
    case checkingModel(expectedBytes: Int64)
    case downloadingModel(receivedBytes: Int64, totalBytes: Int64)
    case validatingModel(byteCount: Int64)
    case loadingModel(startedAt: Date)
    case modelReady
    case rendering(NarrationRenderUnitStatus)
    case heldByBackpressure(NarrationRenderUnitStatus?)
    case complete
    case noNarratableText
    case blocked(message: String)
    case cancelled
    case failed(message: String)
}

nonisolated enum NarrationPlaybackActivity: Equatable, Sendable {
    case notStarted
    case loading(chapterDisplayNumber: Int?)
    case playing(chapterDisplayNumber: Int?)
    case paused(chapterDisplayNumber: Int?)
    case waitingForRender(chapterDisplayNumber: Int?)
    case resuming(chapterDisplayNumber: Int?)
    case stopped
    case completed
    case failed(message: String)
}

nonisolated struct NarrationBufferStatus: Equatable, Sendable {
    var totalSegments = 0
    var queuedSegments = 0
    var currentPlaybackIndex = 0

    var readyAhead: Int {
        max(0, queuedSegments - currentPlaybackIndex - 1)
    }
}

nonisolated struct NarrationEventDescriptor: Equatable, Sendable {
    enum Category: String, Equatable, Sendable {
        case preparation, model, voice, render, buffer, playback, error
    }
    enum Severity: Equatable, Sendable { case info, notice, warning, error }

    let category: Category
    let severity: Severity
    let message: String
    let developerMessage: String
    let privateDetail: String?

    init(
        category: Category, severity: Severity, message: String,
        developerMessage: String, privateDetail: String? = nil
    ) {
        self.category = category
        self.severity = severity
        self.message = message
        self.developerMessage = developerMessage
        self.privateDetail = privateDetail
    }
}

nonisolated struct NarrationEvent: Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let descriptor: NarrationEventDescriptor

    var category: NarrationEventDescriptor.Category { descriptor.category }
    var severity: NarrationEventDescriptor.Severity { descriptor.severity }
    var message: String { descriptor.message }
}

nonisolated struct NarrationStatusSnapshot: Equatable, Sendable {
    var render: NarrationRenderActivity = .idle
    var playback: NarrationPlaybackActivity = .notStarted
    var buffer = NarrationBufferStatus()
    var defaultVoiceID: VoiceID?
}

nonisolated struct NarrationRenderProgress: Equatable, Sendable {
    let chapterDisplayNumber: Int
    let segmentIndex: Int?
    let voiceID: VoiceID
    let completedBlocks: Int
    let totalBlocks: Int
    let timestamp: Date
}
```

- [ ] **Step 4: Implement session mutation, coalescing, and privacy-safe logging**

In `NarrationState.swift`, import `OSLog`; add `private(set) var snapshot`, `private(set) var events`, `private(set) var hasSession`, a 200-event cap, and a five-percent download milestone. Keep logging centralized:

```swift
private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Echo",
    category: "NarrationStatus")
private let eventLimit = 200
private var lastDownloadMilestone = -1

func record(_ descriptor: NarrationEventDescriptor, at date: Date = Date()) {
    let event = NarrationEvent(id: UUID(), timestamp: date, descriptor: descriptor)
    events.append(event)
    if events.count > eventLimit {
        events.removeFirst(events.count - eventLimit)
    }
    switch (descriptor.severity, descriptor.privateDetail) {
    case (.info, .some(let detail)):
        logger.info("\(descriptor.developerMessage, privacy: .public) detail=\(detail, privacy: .private)")
    case (.notice, .some(let detail)):
        logger.notice("\(descriptor.developerMessage, privacy: .public) detail=\(detail, privacy: .private)")
    case (.warning, .some(let detail)):
        logger.warning("\(descriptor.developerMessage, privacy: .public) detail=\(detail, privacy: .private)")
    case (.error, .some(let detail)):
        logger.error("\(descriptor.developerMessage, privacy: .public) detail=\(detail, privacy: .private)")
    case (.info, nil): logger.info("\(descriptor.developerMessage, privacy: .public)")
    case (.notice, nil): logger.notice("\(descriptor.developerMessage, privacy: .public)")
    case (.warning, nil): logger.warning("\(descriptor.developerMessage, privacy: .public)")
    case (.error, nil): logger.error("\(descriptor.developerMessage, privacy: .public)")
    }
}
```

`reportModelDownload` must clamp byte counts, update `snapshot.render` on every call, append only the first sample and new five-percent milestones, and return `true` only when a new milestone was recorded. `beginSession` must clear the prior event history before recording `Narration requested`; `transitionRender` and `transitionPlayback` must update the snapshot and optionally call `record` in the same main-actor turn.

- [ ] **Step 5: Run focused tests to verify GREEN**

Run:

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/NarrationStatusTypesTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/NarrationStateTests
```

Expected: build succeeds and both suites pass with zero failures.

- [ ] **Step 6: Commit the state slice**

```bash
git add EchoCore/Services/Narration/NarrationStatusTypes.swift EchoCore/Services/Narration/NarrationState.swift EchoTests/NarrationStatusTypesTests.swift EchoTests/NarrationStateTests.swift
git commit -m "feat(narration): model observable lifecycle state"
```

---

### Task 2: Pure Status and Lock-Screen Presentation

**Files:**
- Create: `EchoCore/Services/Narration/NarrationStatusPresentation.swift`
- Create: `EchoTests/NarrationStatusPresentationTests.swift`

**Interfaces:**
- Consumes: `NarrationStatusSnapshot` and `NarrationEvent` from Task 1.
- Produces: `NarrationStatusPresentation` and `NarrationStatusFormatter.presentation(for:hasSession:now:)`.
- Produces: deterministic decimal `megabyteText(receivedBytes:totalBytes:)` used by both iOS and tests.

- [ ] **Step 1: Write failing precedence and copy tests**

Cover simultaneous work, waiting, slow synthesis, bytes, all-rendered playback, and failure:

```swift
@Suite struct NarrationStatusPresentationTests {
    @Test func combinesPlayingRenderingAndBuffer() {
        let now = Date(timeIntervalSince1970: 200)
        var snapshot = NarrationStatusSnapshot()
        snapshot.playback = .playing(chapterDisplayNumber: 2)
        snapshot.render = .rendering(
            NarrationRenderUnitStatus(
                chapterDisplayNumber: 4, segmentIndex: 0,
                voiceID: VoiceID("af_heart"), completedBlocks: 8,
                totalBlocks: 19, startedAt: now, lastProgressAt: now))
        snapshot.buffer = NarrationBufferStatus(
            totalSegments: 8, queuedSegments: 3, currentPlaybackIndex: 1)

        let value = NarrationStatusFormatter.presentation(
            for: snapshot, hasSession: true, now: now)
        #expect(value?.primaryText == "Playing chapter 2")
        #expect(value?.secondaryText == "Rendering chapter 4 · 42% · 1 ready ahead")
        #expect(value?.progress == 8.0 / 19.0)
        #expect(value?.lockScreenSubtitle == "Rendering chapter 4 · 42% · 1 ready ahead")
    }

    @Test func queueWaitOutranksGenericPause() {
        var snapshot = NarrationStatusSnapshot()
        snapshot.playback = .waitingForRender(chapterDisplayNumber: 3)
        snapshot.render = .rendering(
            NarrationRenderUnitStatus(
                chapterDisplayNumber: 3, segmentIndex: 0,
                voiceID: VoiceID("af_heart"), completedBlocks: 5,
                totalBlocks: 7, startedAt: .distantPast, lastProgressAt: .distantPast))
        let value = NarrationStatusFormatter.presentation(
            for: snapshot, hasSession: true, now: .distantPast)
        #expect(value?.primaryText == "Waiting for chapter 3")
        #expect(value?.secondaryText == "Rendering 71%")
    }

    @Test func reportsExactDecimalMegabytes() {
        #expect(
            NarrationStatusFormatter.megabyteText(
                receivedBytes: 134_000_000, totalBytes: 163_234_740)
                == "134 of 163 MB")
    }

    @Test func reportsLongBlockWithoutCallingItFailed() {
        let start = Date(timeIntervalSince1970: 100)
        var snapshot = NarrationStatusSnapshot()
        snapshot.render = .rendering(
            NarrationRenderUnitStatus(
                chapterDisplayNumber: 1, segmentIndex: 0,
                voiceID: VoiceID("af_heart"), completedBlocks: 7,
                totalBlocks: 19, startedAt: start, lastProgressAt: start))
        let value = NarrationStatusFormatter.presentation(
            for: snapshot, hasSession: true,
            now: Date(timeIntervalSince1970: 134))
        #expect(value?.secondaryText == "Still synthesizing block 8 · no update for 34s")
        #expect(value?.isFailure == false)
    }
}
```

- [ ] **Step 2: Run the focused build to verify RED**

Run:

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
```

Expected: build fails because `NarrationStatusFormatter` and `NarrationStatusPresentation` do not exist.

- [ ] **Step 3: Implement the pure presentation model and precedence**

Use this exact output shape:

```swift
nonisolated struct NarrationStatusPresentation: Equatable, Sendable {
    let primaryText: String
    let secondaryText: String?
    let progress: Double?
    let systemImage: String
    let showsActivity: Bool
    let isFailure: Bool
    let accessibilityLabel: String
    let lockScreenSubtitle: String?
}

nonisolated enum NarrationStatusFormatter {
    static func presentation(
        for snapshot: NarrationStatusSnapshot,
        hasSession: Bool,
        now: Date
    ) -> NarrationStatusPresentation?

    static func megabyteText(receivedBytes: Int64, totalBytes: Int64) -> String
}
```

Implement precedence in this order: render/playback failure or blocked/no-text; queue wait; model check/download/validation/load/ready; playing; paused; first render before playback; all-rendered playback; completed/cancelled/stopped. Resolve voice display names through `VoiceCatalog.voice(for:)`, falling back to `voiceID.rawValue`. Clamp every percentage to `0–100`. At 30 seconds without a render milestone, replace only the secondary render detail with the elapsed diagnostic; do not change `isFailure`.

- [ ] **Step 4: Run the formatter suite to verify GREEN**

Run:

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/NarrationStatusPresentationTests
```

Expected: all presentation tests pass.

- [ ] **Step 5: Commit the formatting slice**

```bash
git add EchoCore/Services/Narration/NarrationStatusPresentation.swift EchoTests/NarrationStatusPresentationTests.swift
git commit -m "feat(narration): format persistent status summaries"
```

---

### Task 3: Exact ONNX Model-Delivery Progress

**Files:**
- Modify: `EchoCore/Services/Narration/TTSEngine.swift`
- Modify: `EchoCore/Services/Narration/ProgressFanOut.swift`
- Modify: `EchoCore/Services/Narration/OnnxKokoroEngine.swift`
- Modify: `EchoCore/Services/Narration/HeadlessNarrationRunner.swift`
- Modify: `EchoTests/NarrationPrepareStatusTests.swift`
- Modify: `EchoTests/HeadlessNarrationRunnerParallelTests.swift`
- Modify: `EchoTests/OnnxKokoroEnginePrepareTests.swift`
- Modify: `EchoTests/OnnxKokoroEngineModelDeliveryTests.swift`

**Interfaces:**
- Replaces: fractional `downloadingModels` and misleading `compilingModels` cases.
- Produces: `NarrationPrepareProgress.checkingModel`, `.modelCacheHit`, `.downloadingModel`, `.validatingModel`, `.loadingModel`, and `.ready`.
- Preserves: monotonic batch band `0–0.15` and headless preparation fraction `0–1`.

- [ ] **Step 1: Rewrite progress tests against the exact contract**

Use these cases in every affected suite:

```swift
nonisolated enum NarrationPrepareProgress: Sendable, Equatable {
    case checkingModel(expectedBytes: Int64)
    case modelCacheHit(byteCount: Int64)
    case downloadingModel(receivedBytes: Int64, totalBytes: Int64)
    case validatingModel(byteCount: Int64)
    case loadingModel
    case ready
}
```

Add a late-join test that expects immediate replay of the latest nonterminal state:

```swift
@Test func fanOutReplaysLatestProgressToLateJoiner() {
    let fan = ProgressFanOut()
    let late = ProgressBox()
    fan.emit(.downloadingModel(receivedBytes: 50, totalBytes: 100))
    fan.add { late.append($0) }
    #expect(late.items == [.downloadingModel(receivedBytes: 50, totalBytes: 100)])
}
```

Update headless expectations so 50/100 maps to `0.45`, validation/loading map to `0.9`, and ready maps to `1.0`. Update batch text to `Downloading narration model… 50% · 50 of 100 MB`, `Narration model cached · 163 MB`, and `Loading narration model…`.

- [ ] **Step 2: Run the focused build to verify RED**

Run:

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
```

Expected: build fails because production still exposes the old enum cases.

- [ ] **Step 3: Replace the preparation contract and latest-state replay**

Replace the enum in `TTSEngine.swift`, update both pure progress mappers exhaustively, and make the default protocol implementation finish with `.ready`:

```swift
func prepare(
    progress: @escaping @Sendable (NarrationPrepareProgress) -> Void
) async throws {
    try await prepare()
    progress(.ready)
}
```

In `ProgressFanOut`, replace `terminalProgress` with `latestProgress`. `add` must replay `latestProgress` immediately and subscribe the joiner only when the replayed value is not `.ready`. `clear()` resets subscribers and `latestProgress`.

- [ ] **Step 4: Emit cache, byte, validation, and session-load progress**

Change `OnnxKokoroEngine.modelProvider` and `ensureModel` to accept a `NarrationPrepareProgress` callback. Emit in this order:

```swift
progress(.checkingModel(expectedBytes: Int64(expectedModelBytes)))
```

For an exact-size destination file:

```swift
progress(.modelCacheHit(byteCount: Int64(expectedModelBytes)))
return dest
```

For a download, emit zero before reading and exact bytes after each 64 KB write and the final partial write:

```swift
progress(.downloadingModel(receivedBytes: 0, totalBytes: Int64(expectedModelBytes)))
progress(
    .downloadingModel(
        receivedBytes: Int64(received),
        totalBytes: Int64(expectedModelBytes)))
```

After exact-size validation emit `.validatingModel(byteCount:)`; immediately before `ORTSession` construction emit `.loadingModel`; after both waveform and best-effort duration sessions are stored emit `.ready`. Preserve cancellation and failed-initialization cache clearing.

- [ ] **Step 5: Run exact model and progress suites to verify GREEN**

Run:

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/NarrationPrepareStatusTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/HeadlessNarrationRunnerParallelTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/OnnxKokoroEnginePrepareTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/OnnxKokoroEngineModelDeliveryTests
```

Expected: all four suites pass; no case still uses `compilingModels` or `downloadingModels`.

- [ ] **Step 6: Commit exact model progress**

```bash
git add EchoCore/Services/Narration/TTSEngine.swift EchoCore/Services/Narration/ProgressFanOut.swift EchoCore/Services/Narration/OnnxKokoroEngine.swift EchoCore/Services/Narration/HeadlessNarrationRunner.swift EchoTests/NarrationPrepareStatusTests.swift EchoTests/HeadlessNarrationRunnerParallelTests.swift EchoTests/OnnxKokoroEnginePrepareTests.swift EchoTests/OnnxKokoroEngineModelDeliveryTests.swift
git commit -m "feat(narration): report exact model preparation progress"
```

---

### Task 4: Visible Planning and Model Preparation in PlayerModel

**Files:**
- Modify: `EchoCore/ViewModels/PlayerModel+Narration.swift`
- Modify: `EchoCore/Views/NowPlayingTab.swift`
- Modify: `EchoTests/PlayerModelTests.swift`
- Modify: `EchoTests/NowPlayingLayoutTests.swift`
- Modify: `EchoTests/ArticleWorkshop/AnthologyBuilderViewModelTests.swift`

**Interfaces:**
- Consumes: Task 1 state transitions and Task 3 preparation cases.
- Produces: explicit session creation before planning, guarded preparation mapping, selected-voice events, and `publishNarrationStatusToNowPlaying()`.
- Removes: non-reporting `.task(id:)` model prewarm from `NowPlayingTab`.

- [ ] **Step 1: Write failing player preparation tests**

Replace the stale-callback test's legacy phase assertions with snapshot assertions and add source-order guards:

```swift
@Test func preparationProgressMapsToExactLifecycle() {
    let model = PlayerModel()
    let bookURL = URL(fileURLWithPath: "/same-book", isDirectory: true)
    model.folderURL = bookURL
    let operation = model.replaceNarrationOperation()
    model.narrationPlaybackState.beginSession(defaultVoiceID: VoiceID("af_heart"))

    model.handleNarrationPreparationProgress(
        .downloadingModel(receivedBytes: 50, totalBytes: 100),
        operation: operation, audiobookID: bookURL.absoluteString)

    #expect(
        model.narrationPlaybackState.snapshot.render
            == .downloadingModel(receivedBytes: 50, totalBytes: 100))
}

@Test func narrationSessionStartsBeforeImportAwait() throws {
    let source = try Self.source(named: "PlayerModel+Narration.swift")
    let begin = try #require(source.range(of: "narrationPlaybackState.beginSession("))
    let importAwait = try #require(
        source.range(of: "await self.playerLoadingCoordinator.documentImportTask?.value"))
    #expect(begin.lowerBound < importAwait.lowerBound)
}

@Test func nowPlayingDoesNotSilentlyPrewarmNarrationModel() throws {
    let source = try Self.source(named: "NowPlayingTab.swift")
    #expect(!source.contains("try? await model.narrationTTS.prepare()"))
}
```

Place `nowPlayingDoesNotSilentlyPrewarmNarrationModel` in `NowPlayingLayoutTests`, whose source resolver targets `EchoCore/Views`; place the first two tests in `PlayerModelTests`, whose resolver targets `EchoCore/ViewModels`.

- [ ] **Step 2: Run the focused build/tests to verify RED**

Run:

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/PlayerModelTests
```

Expected: the new lifecycle and prewarm assertions fail.

- [ ] **Step 3: Begin the session synchronously and remove silent prewarm**

Immediately after capability/database guards and before launching the render task, call:

```swift
narrationPlaybackState.beginSession(defaultVoiceID: voice.id)
narrationPlaybackState.transitionRender(
    to: .planning,
    event: .init(
        category: .preparation, severity: .notice,
        message: String(localized: "Preparing narration plan"),
        developerMessage: "preparation planning started"))
```

Delete the `model.narrationTTS.prepare()` prewarm from `NowPlayingTab.task(id:)`, leaving visual-listening reload intact. After `NarrationPlaybackPlanPreparation.prepare` succeeds, update the buffer's `totalSegments`, record the default voice display name, and record the override count without logging book identity.

Update `AnthologyBuilderViewModelTests` source-copy assertion from `Voice models ready` to `Narration model ready`; this remains a source contract for the workshop's player readiness path.

- [ ] **Step 4: Map every preparation case through guarded state transitions**

In `handleNarrationPreparationProgress`, preserve `NarrationOperationToken` and active-book guards, then map:

```swift
case .checkingModel(let expectedBytes):
    narrationPlaybackState.transitionRender(
        to: .checkingModel(expectedBytes: expectedBytes),
        event: .init(
            category: .model, severity: .info,
            message: String(localized: "Checking narration model"),
            developerMessage: "model cache check expectedBytes=\(expectedBytes)"))
case .modelCacheHit(let byteCount):
    narrationPlaybackState.transitionRender(
        to: .validatingModel(byteCount: byteCount),
        event: .init(
            category: .model, severity: .notice,
            message: String(localized: "Narration model found in cache"),
            developerMessage: "model cache hit bytes=\(byteCount)"))
case .downloadingModel(let receivedBytes, let totalBytes):
    let publishesMilestone = narrationPlaybackState.reportModelDownload(
        receivedBytes: receivedBytes, totalBytes: totalBytes)
    if publishesMilestone { publishNarrationStatusToNowPlaying() }
case .validatingModel(let byteCount):
    narrationPlaybackState.transitionRender(
        to: .validatingModel(byteCount: byteCount),
        event: .init(
            category: .model, severity: .info,
            message: String(localized: "Validating narration model"),
            developerMessage: "model validating bytes=\(byteCount)"))
case .loadingModel:
    narrationPlaybackState.transitionRender(
        to: .loadingModel(startedAt: Date()),
        event: .init(
            category: .model, severity: .notice,
            message: String(localized: "Loading narration model"),
            developerMessage: "model session loading"))
case .ready:
    narrationPlaybackState.transitionRender(
        to: .modelReady,
        event: .init(
            category: .model, severity: .notice,
            message: String(localized: "Narration model ready"),
            developerMessage: "model session ready"))
```

Call `publishNarrationStatusToNowPlaying()` on every discrete transition and only on download milestones. This helper calls `progressPresenter.updateNowPlayingInfo(isPaused: !isPlaying)`; Task 7 changes the subtitle provider to consume the formatter.

- [ ] **Step 5: Run player and layout suites to verify GREEN**

Run:

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/PlayerModelTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/NowPlayingLayoutTests
```

Expected: preparation mapping, stale-callback rejection, session ordering, and no-prewarm tests pass.

- [ ] **Step 6: Commit preparation visibility**

```bash
git add EchoCore/ViewModels/PlayerModel+Narration.swift EchoCore/Views/NowPlayingTab.swift EchoTests/PlayerModelTests.swift EchoTests/NowPlayingLayoutTests.swift EchoTests/ArticleWorkshop/AnthologyBuilderViewModelTests.swift
git commit -m "feat(narration): expose preparation lifecycle"
```

---

### Task 5: Structured Render and Playable-Buffer Progress

**Files:**
- Modify: `EchoCore/Services/Narration/NarrationService.swift`
- Modify: `EchoCore/ViewModels/PlayerModel+Narration.swift`
- Modify: `EchoTests/NarrationServiceTests.swift`
- Modify: `EchoTests/PlayerModelTests.swift`
- Modify: `EchoTests/NarrationRenderPolicyTests.swift`

**Interfaces:**
- Consumes: `NarrationRenderProgress`, `NarrationRenderUnitStatus`, state transitions, and prepared segment count.
- Changes: `NarrationService.renderSegment(chapterIndex:sourceChapterKey:chapterDisplayNumber:segmentIndex:blocks:voice:chapterTitle:onBlockProgress:) async throws -> RenderedNarrationFile`.
- Changes: all `onBlockProgress` callbacks to `@MainActor (NarrationRenderProgress) -> Void`.
- Produces: accurate start/block/finalize/cache-hit/queue-insertion/backpressure/all-rendered state and events.

- [ ] **Step 1: Write failing structured-progress tests**

Update the service fixture callback and assert exact counts rather than reconstructed fractions:

```swift
@Test func renderSegmentReportsZeroThenEachSpeakableBlock() async throws {
    let db = try DatabaseService(inMemory: ())
    let chapterBlocks = try seed(db, ["One.", "Two.", "Three."])
    let service = makeService(
        db,
        tts: MockTTSEngine(secondsPerChar: 0.1),
        writer: MockAudioWriter())
    var values: [NarrationRenderProgress] = []
    _ = try await service.renderSegment(
        chapterIndex: 0, chapterDisplayNumber: 1, segmentIndex: 0,
        blocks: chapterBlocks, voice: VoiceID("af_heart"),
        onBlockProgress: { values.append($0) })

    #expect(values.map(\.completedBlocks) == [0, 1, 2, 3])
    #expect(values.allSatisfy { $0.totalBlocks == 3 })
    #expect(values.allSatisfy { $0.chapterDisplayNumber == 1 })
    #expect(values.allSatisfy { $0.segmentIndex == 0 })
    #expect(values.allSatisfy { $0.voiceID == VoiceID("af_heart") })
}
```

Add a PlayerModel/state test that updates a buffer with `queuedSegments: 3`, `currentPlaybackIndex: 1`, and asserts `readyAhead == 1`. Update stale block-progress tests to pass a full `NarrationRenderProgress` and assert stale operations cannot change `snapshot.render` or append events.

- [ ] **Step 2: Run focused build/tests to verify RED**

Run:

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/NarrationServiceTests
```

Expected: callback signature and void `renderSegment` no longer satisfy the tests.

- [ ] **Step 3: Emit structured service progress and return rendered metadata**

In `renderNarrationFile`, invoke `onBlockProgress` immediately after the render plan supplies `speakableBlockIDs.count`, then after every speakable block:

```swift
onBlockProgress?(
    NarrationRenderProgress(
        chapterDisplayNumber: chapterDisplayNumber,
        segmentIndex: segmentIndex,
        voiceID: voice,
        completedBlocks: renderedSpeakableBlocks,
        totalBlocks: speakableBlockIDs.count,
        timestamp: Date()))
```

Mark `renderSegment` `@discardableResult`, return its `RenderedNarrationFile`, and preserve persistence before return. Update every callback/call site to compile.

- [ ] **Step 4: Drive render, backpressure, cache, and buffer state from the player loop**

Before each uncached render, transition to a zero-block `NarrationRenderUnitStatus` and record the voice display name. When `NarrationRenderPolicy.shouldPauseRender` first becomes true, transition once to `.heldByBackpressure`; do not append an event on each one-second poll. Transition back to `.rendering` immediately before synthesis.

In `handleNarrationBlockProgress`, preserve the operation-token guard, rebuild the unit with the original `startedAt`, update `lastProgressAt`, append one block-completion event, and publish lock-screen status.

Capture the returned render result:

```swift
let rendered = try await service.renderSegment(
    chapterIndex: segment.chapterIndex,
    sourceChapterKey: segment.sourceChapterKey,
    chapterDisplayNumber: segment.chapterDisplayNumber,
    segmentIndex: segment.segmentIndex,
    blocks: segment.blocks,
    voice: segment.voice,
    chapterTitle: segment.chapterTitle,
    onBlockProgress: { [weak self] progress in
        self?.handleNarrationBlockProgress(
            progress, operation: operation, audiobookID: audiobookID)
    })
narrationPlaybackState.record(
    .init(
        category: .render, severity: .notice,
        message: String(
            localized: "Chapter \(segment.chapterDisplayNumber) ready · \(Int(rendered.duration))s audio"),
        developerMessage:
            "render ready chapter=\(segment.chapterDisplayNumber) segment=\(segment.segmentIndex) durationSeconds=\(Int(rendered.duration))"))
```

For cached segments, record `Using cached narration for chapter N`. After every append/prepend, set `NarrationBufferStatus(totalSegments:segments.count, queuedSegments:tracks.count, currentPlaybackIndex:state.currentIndex)`. After the final segment, transition render to `.complete`; do not mark playback completed.

- [ ] **Step 5: Run render, policy, and player tests to verify GREEN**

Run:

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/NarrationServiceTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/NarrationRenderPolicyTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/PlayerModelTests
```

Expected: structured progress, stale-callback rejection, unchanged look-ahead policy, playable-buffer counts, and separate render completion all pass.

- [ ] **Step 6: Commit render/buffer progress**

```bash
git add EchoCore/Services/Narration/NarrationService.swift EchoCore/ViewModels/PlayerModel+Narration.swift EchoTests/NarrationServiceTests.swift EchoTests/PlayerModelTests.swift EchoTests/NarrationRenderPolicyTests.swift
git commit -m "feat(narration): expose render and buffer progress"
```

---

### Task 6: Playback Pause, Queue-Wait, Resume, and Natural-End Semantics

**Files:**
- Modify: `EchoCore/Services/PlaybackController.swift`
- Modify: `EchoCore/ViewModels/PlayerModel.swift`
- Modify: `EchoCore/ViewModels/PlayerModel+Narration.swift`
- Modify: `EchoTests/PlaybackControllerTests.swift`
- Modify: `EchoTests/PlayerModelTests.swift`

**Interfaces:**
- Produces: `PlaybackActivityChange.playing`, `.paused`, `.waitingForNarration`, and `.reachedNaturalEnd`.
- Changes: `coordinator_playStateChanged` from a Boolean callback to `(PlaybackActivityChange) -> Void`.
- Changes: `pause(reason: PlaybackPauseReason = .userOrSystem)` and `nextTrack(naturalEnd: Bool = false)`.
- Produces: narration playback transitions and event ordering for wait -> ready -> resume -> playing.
- Produces in `PlayerModel`: `currentNarrationChapterDisplayNumber: Int?`, `currentRenderingChapterDisplayNumber: Int?`, and `playbackEvent(_:severity:) -> NarrationEventDescriptor`.

- [ ] **Step 1: Write failing controller transition tests**

Add exact callback assertions:

```swift
@Test func ordinaryPauseAndNarrationGapEmitDifferentChanges() {
    let ordinary = PlaybackController()
    var ordinaryChanges: [PlaybackActivityChange] = []
    ordinary.coordinator_playStateChanged = { ordinaryChanges.append($0) }
    ordinary.pause()
    #expect(ordinaryChanges.last == .paused)

    let gap = PlaybackController()
    var gapChanges: [PlaybackActivityChange] = []
    gap.coordinator_playStateChanged = { gapChanges.append($0) }
    gap.state.tracks = [
        Track(url: URL(fileURLWithPath: "/tmp/ch0.m4a"), title: "Chapter 1")
    ]
    gap.state.currentIndex = 0
    gap.state.narrationRenderInFlight = true
    gap.nextTrack()
    #expect(gapChanges.last == .waitingForNarration)
    #expect(gap.state.awaitingNarrationChapter)
}

@Test func naturalEndIsNotEmittedForManualNextAtQueueEnd() {
    let controller = PlaybackController()
    var changes: [PlaybackActivityChange] = []
    controller.coordinator_playStateChanged = { changes.append($0) }
    controller.state.tracks = [
        Track(url: URL(fileURLWithPath: "/tmp/ch0.m4a"), title: "Chapter 1")
    ]
    controller.nextTrack()
    #expect(!changes.contains(.reachedNaturalEnd))
    controller.nextTrack(naturalEnd: true)
    #expect(changes.last == .reachedNaturalEnd)
}
```

Add a state test that transitions `.waitingForRender(3)`, then `.resuming(3)`, then `.playing(3)`, and asserts event messages keep that order.

- [ ] **Step 2: Run playback tests to verify RED**

Run:

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/PlaybackControllerTests
```

Expected: typed changes, pause reason, and natural-end API are missing.

- [ ] **Step 3: Add typed playback changes without changing transport behavior**

Add:

```swift
nonisolated enum PlaybackActivityChange: Equatable, Sendable {
    case playing
    case paused
    case waitingForNarration
    case reachedNaturalEnd
}

nonisolated enum PlaybackPauseReason: Equatable, Sendable {
    case userOrSystem
    case narrationQueueWait
}
```

`play()` emits `.playing`. `pause(reason:)` retains the required clear-before-gap-set ordering and emits `.paused` or `.waitingForNarration` from the reason. The queue-gap branch calls `pause(reason: .narrationQueueWait)` and then sets `awaitingNarrationChapter = true`. `nextTrack(naturalEnd:)` emits `.reachedNaturalEnd` only when there is no next enabled track, no narration render in flight, and `naturalEnd == true`. Both terminal calls from `handleTrackEnded()` pass `naturalEnd: true`; manual navigation keeps the default `false`.

- [ ] **Step 4: Map typed changes into narration playback state**

Update `PlayerModel`'s coordinator closure to retain session-recorder/alignment behavior while switching on the typed change. When `narrationPlaybackState.hasSession`:

```swift
case .playing:
    narrationPlaybackState.transitionPlayback(
        to: .playing(chapterDisplayNumber: currentNarrationChapterDisplayNumber),
        event: playbackEvent("Playing", severity: .notice))
case .paused:
    narrationPlaybackState.transitionPlayback(
        to: .paused(chapterDisplayNumber: currentNarrationChapterDisplayNumber),
        event: playbackEvent("Paused", severity: .notice))
case .waitingForNarration:
    narrationPlaybackState.transitionPlayback(
        to: .waitingForRender(chapterDisplayNumber: currentRenderingChapterDisplayNumber),
        event: playbackEvent("Waiting for rendered narration", severity: .warning))
case .reachedNaturalEnd:
    narrationPlaybackState.transitionPlayback(
        to: .completed,
        event: playbackEvent("Narration playback complete", severity: .notice))
```

Implement `playbackEvent(_:severity:)` so its developer message contains only stable activity names and numeric chapter values. Derive `currentNarrationChapterDisplayNumber` from `NarrationFileNaming.location(fromFileName:)`, falling back to `currentIndex + 1`; never log a path or title. In the render-loop queue-wait recovery, transition to `.resuming` and record `Chapter N ready · resuming` before clearing the flag and calling `nextTrack()`.

If the sleep timer fires during a queue wait, clear auto-resume as today and transition to `.paused`, recording `Narration wait cancelled by sleep timer`.

- [ ] **Step 5: Run playback and player suites to verify GREEN**

Run:

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/PlaybackControllerTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/PlayerModelTests
```

Expected: ordinary pause, queue wait, natural completion, sleep-timer cancellation, and auto-resume ordering pass without changing existing transport tests.

- [ ] **Step 6: Commit playback semantics**

```bash
git add EchoCore/Services/PlaybackController.swift EchoCore/ViewModels/PlayerModel.swift EchoCore/ViewModels/PlayerModel+Narration.swift EchoTests/PlaybackControllerTests.swift EchoTests/PlayerModelTests.swift
git commit -m "feat(narration): distinguish playback waits and pauses"
```

---

### Task 7: Persistent Expandable iOS Card and Lock-Screen Copy

**Files:**
- Modify: `EchoCore/Views/Narration/NarrationStatusView.swift`
- Modify: `EchoCore/Views/NowPlayingTab.swift`
- Modify: `EchoCore/Views/Player/ExperimentalNowPlayingView.swift`
- Modify: `EchoCore/ViewModels/PlayerModel.swift`
- Modify: `EchoCore/ViewModels/PlayerModel+Narration.swift`
- Delete: `EchoCore/Services/Narration/NarrationProgressText.swift`
- Modify: `EchoTests/NowPlayingLayoutTests.swift`
- Create: `EchoTests/NarrationStatusViewContractTests.swift`
- Modify: `EchoTests/PlayerModelTests.swift`
- Delete: `EchoTests/NarrationProgressTextTests.swift`

**Interfaces:**
- Consumes: `NarrationStatusFormatter`, `NarrationState.snapshot`, and `NarrationState.events`.
- Produces: persistent `NarrationStatusView`, inline `NarrationEventRow`, and operational `PlaybackProgressPresenter.currentSubtitleProvider`.
- Keeps: card hidden only when `state.hasSession == false`.

- [ ] **Step 1: Write failing layout and view-contract tests**

Add a placement test that reads both actual sources without a fallback fixture:

```swift
@Test func bothIOSLayoutsMountTheNarrationStatusCard() throws {
    let standard = try Self.source(named: "NowPlayingTab.swift")
    let experimental = try Self.source(named: "Player/ExperimentalNowPlayingView.swift")
    #expect(standard.contains("NarrationStatusView(state: model.narrationPlaybackState)"))
    #expect(experimental.contains("NarrationStatusView(state: model.narrationPlaybackState)"))
}
```

In `NarrationStatusViewContractTests`, assert the source contains `DisclosureGroup`, reverse chronological `state.events.reversed()`, a bounded event-list frame, `accessibilityIdentifier("narration.status.details")`, and the native SwiftUI `.accessibilityAddTraits(.updatesFrequently)` API. Add a PlayerModel source test that the Now Playing subtitle provider calls `NarrationStatusFormatter.presentation` before falling back to `currentSubtitle`.

Make the view-contract suite self-contained with this resolver:

```swift
private static func narrationStatusSource() throws -> String {
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while directory.path != "/" {
        let candidate = directory.deletingLastPathComponent()
            .appendingPathComponent(
                "EchoCore/Views/Narration/NarrationStatusView.swift")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return try String(contentsOf: candidate, encoding: .utf8)
        }
        directory.deleteLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile)
}
```

- [ ] **Step 2: Run layout/player tests to verify RED**

Run:

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/NowPlayingLayoutTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/NarrationStatusViewContractTests
```

Expected: experimental placement, disclosure history, and operational subtitle assertions fail.

- [ ] **Step 3: Replace the transient card with the persistent presentation-driven view**

Use `TimelineView(.periodic(from: .now, by: 1))` only while `state.hasSession` so elapsed no-progress copy updates without mutating state. The collapsed header must render from `NarrationStatusFormatter.presentation`, including symbol/spinner, primary, secondary, and optional determinate `ProgressView`.

The expanded content must use this structure:

```swift
DisclosureGroup(isExpanded: $isExpanded) {
    ScrollView {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(state.events.reversed()) { event in
                NarrationEventRow(event: event)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxHeight: 220)
} label: {
    Text("Details")
        .font(.caption.bold())
}
.accessibilityIdentifier("narration.status.details")
.accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
```

Define the event row in the same file; it owns only event rendering:

```swift
private struct NarrationEventRow: View {
    let event: NarrationEvent

    private var systemImage: String {
        switch event.category {
        case .preparation: "list.bullet.clipboard"
        case .model: "arrow.down.circle"
        case .voice: "person.wave.2"
        case .render: "waveform.badge.plus"
        case .buffer: "rectangle.stack"
        case .playback: "play.circle"
        case .error: "exclamationmark.triangle"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .accessibilityHidden(true)
            Text(event.timestamp, format: .dateTime.hour().minute().second())
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(event.message)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}
```

Format event timestamps with date omitted and standard time. Use category symbols without relying on color as the only carrier of meaning. Apply `.accessibilityAddTraits(.updatesFrequently)` to the combined collapsed summary, not the per-block event list. Xcode 26.6's iOS 26.5 SwiftUI SDK exposes no `accessibilityLiveRegion` modifier; the native frequently-updated trait preserves the noninterrupting status-update intent without manually posting per-block announcements. Respect Reduce Motion by using no insertion transition when `accessibilityReduceMotion` is true.

- [ ] **Step 4: Mount the same card in both layouts**

Keep the standard placement in `narrationNudgeSection`. In `ExperimentalNowPlayingView`, insert:

```swift
if model.isNarrationBook && NarrationCapability.supportsOnDeviceNarration {
    NarrationStatusView(state: model.narrationPlaybackState)
        .padding(.horizontal, NowPlayingLayout.horizontalPadding)
        .padding(.top, 8)
}
```

Place it between `ExperimentalMetadataView` and `PlayerScrubberView`. Do not create an experimental-only status view or copy state.

- [ ] **Step 5: Provide operational lock-screen subtitles without replacing in-app chapter titles**

Change only `progressPresenter.currentSubtitleProvider` wiring:

```swift
progressPresenter.currentSubtitleProvider = { [weak self] in
    guard let self else { return "" }
    return NarrationStatusFormatter.presentation(
        for: self.narrationPlaybackState.snapshot,
        hasSession: self.narrationPlaybackState.hasSession,
        now: Date())?.lockScreenSubtitle ?? self.currentSubtitle
}
```

Do not overwrite `PlaybackState.currentSubtitle` with render progress. Keep `publishNarrationStatusToNowPlaying()` calls on discrete transitions, per-block progress, and five-percent model milestones so MediaPlayer metadata is not updated for each 64 KB chunk.

After those call sites migrate, delete `NarrationProgressText.swift` and its test suite; `NarrationStatusFormatter` is now the only owner of narration status copy.

- [ ] **Step 6: Run presentation, layout, and player suites to verify GREEN**

Run:

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/NarrationStatusPresentationTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/NowPlayingLayoutTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/NarrationStatusViewContractTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/PlayerModelTests
```

Expected: both layouts mount one shared card, expanded-log contract passes, lock-screen copy is derived, and chapter-title behavior remains intact.

- [ ] **Step 7: Commit the UI slice**

```bash
git add EchoCore/Views/Narration/NarrationStatusView.swift EchoCore/Views/NowPlayingTab.swift EchoCore/Views/Player/ExperimentalNowPlayingView.swift EchoCore/ViewModels/PlayerModel.swift EchoCore/ViewModels/PlayerModel+Narration.swift EchoTests/NowPlayingLayoutTests.swift EchoTests/NarrationStatusViewContractTests.swift EchoTests/PlayerModelTests.swift
git add -u EchoCore/Services/Narration/NarrationProgressText.swift EchoTests/NarrationProgressTextTests.swift
git commit -m "feat(ios): show expandable narration status card"
```

---

### Task 8: Terminal Outcomes, Legacy Cleanup, and End-to-End Verification

**Files:**
- Modify: `EchoCore/Services/Narration/NarrationState.swift`
- Modify: `EchoCore/Services/Narration/NarrationService.swift`
- Modify: `EchoCore/ViewModels/PlayerModel+Narration.swift`
- Modify: `EchoCore/ViewModels/PlayerModel.swift`
- Modify: `EchoTests/NarrationStateTests.swift`
- Modify: `EchoTests/NarrationServiceTests.swift`
- Modify: `EchoTests/PlayerModelTests.swift`
- Modify: `EchoTests/ArticleWorkshop/AnthologyChapterVoicesIntegrationTests.swift`

**Interfaces:**
- Removes: stored legacy `phase`, `progress`, `statusMessage`, `debugLog`, `currentChapterIndex`, `totalChapters`, `renderedChapterCount`, and generic `update(phase:progress:statusMessage:)`.
- Keeps: computed `phase` and `isRunning` compatibility projections while existing external/test reporting still consumes them.
- Produces: explicit no-text, blocked, cancellation, render failure, and playback failure outcomes that remain visible.

- [ ] **Step 1: Write failing terminal-outcome tests**

Add direct state assertions and update the existing paywall test:

```swift
@Test func renderCompletionDoesNotCompletePlayback() {
    let state = NarrationState()
    state.beginSession(defaultVoiceID: VoiceID("af_heart"))
    state.transitionPlayback(to: .playing(chapterDisplayNumber: 1), event: nil)
    state.transitionRender(to: .complete, event: nil)
    #expect(state.snapshot.render == .complete)
    #expect(state.snapshot.playback == .playing(chapterDisplayNumber: 1))
}

@Test func noTextBlockedAndFailureRemainVisible() {
    let state = NarrationState()
    state.beginSession(defaultVoiceID: VoiceID("af_heart"))
    state.transitionRender(to: .noNarratableText, event: nil)
    #expect(state.hasSession)
    state.transitionRender(to: .blocked(message: "Narration limit reached"), event: nil)
    #expect(state.hasSession)
    state.transitionRender(to: .failed(message: "Model unavailable"), event: nil)
    #expect(state.hasSession)
}
```

In `PlayerModelTests`, assert the free-tier gate yields `.blocked`, a generic render catch yields `.failed`, and `loadFolder` cancels/logs the old session before reset. Keep stale-book guards intact.

In `NarrationServiceTests`, replace all three `state.debugLog.contains` assertions with `state.events.contains { $0.message.contains(...) }`, preserving the nonfatal advisory-report and fallback-discovery coverage.

- [ ] **Step 2: Run state/player suites to verify RED**

Run:

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/NarrationStateTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/PlayerModelTests
```

Expected: remaining generic completion/failure paths and legacy state assumptions fail.

- [ ] **Step 3: Convert every terminal path to an explicit transition**

Update `PlayerModel+Narration.swift` as follows:

- Empty planned chapters: render `.noNarratableText`, playback `.stopped`, event `No text to narrate`.
- Free-tier gate: render `.blocked(message:)`, playback `.stopped`, warning event without book identity.
- All segments queued: render `.complete` with `All narration rendered`; leave playback unchanged.
- `CancellationError`: render `.cancelled` only if the operation token is still current; otherwise emit only a privacy-safe cancellation log before the old session is discarded.
- Manifest/plan validation error: render `.failed(localized rebuild message)` and preserve that message in the card.
- All other errors: render `.failed(error.localizedDescription)`; construct the error event with `developerMessage: "render failed type=\(String(reflecting: type(of: error)))"` and `privateDetail: error.localizedDescription`, never a public path-bearing description.

Replace both `NarrationService.state.log(message)` calls with `.warning`/`.error` `NarrationEventDescriptor` records. Their public developer messages are `pronunciation fallback discovery failed` and `advisory report write failed`; their localized error descriptions use `privateDetail`.

Before `loadFolder` resets a live session, record `Narration cancelled because the active book changed`, then reset after the task/token is invalidated.

- [ ] **Step 4: Remove legacy stored mutation and migrate compatibility consumers**

Run:

```bash
rg -n "narrationPlaybackState\.(update|statusMessage|progress|debugLog|complete|fail)" EchoCore EchoTests --glob '*.swift'
rg -n "state\.(update|statusMessage|debugLog|renderedChapterCount)" EchoCore/Services/Narration/NarrationService.swift EchoTests/NarrationServiceTests.swift EchoTests/NarrationStateTests.swift --glob '*.swift'
rg -n "NarrationProgressText" EchoCore EchoTests --glob '*.swift'
```

Expected before cleanup: only known migration sites remain. Replace them with structured transitions/events. Make `phase` a computed mapping with associated-value wildcard patterns:

```swift
var phase: Phase {
    switch (snapshot.render, snapshot.playback) {
    case (.failed(_), _), (.blocked(_), _), (_, .failed(_)): return .failed
    case (.complete, .completed): return .completed
    case (.checkingModel(_), _), (.downloadingModel(_, _), _),
        (.validatingModel(_), _), (.loadingModel(_), _), (.modelReady, _):
        return .preparingEngine
    case (.rendering(_), .playing(_)), (.heldByBackpressure(_), .playing(_)):
        return .renderingAhead
    case (.planning, _), (.rendering(_), _), (.heldByBackpressure(_), _):
        return .preparingChapter
    default: return .idle
    }
}
```

Change `AnthologyChapterVoicesIntegrationTests.Result` to store `NarrationRenderActivity` and `NarrationPlaybackActivity` instead of `NarrationState.Phase`; successful runs assert render `.complete` independently of playback, and invalid-plan runs assert render `.failed`. Remove the generic mutation surface and obsolete chapter counters. Re-run the `rg`; it must return no narration legacy mutations or deleted formatter references.

- [ ] **Step 5: Run focused regression suites**

Run:

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/NarrationStateTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/PlayerModelTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ArticleWorkshop/AnthologyChapterVoicesIntegrationTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/PlaybackControllerTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/NarrationServiceTests
```

Expected: every focused suite passes with zero failures.

- [ ] **Step 6: Run the full unit-test gate**

Run:

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test
```

Expected: `TEST SUCCEEDED`, no test failures, and no compiler errors.

- [ ] **Step 7: Perform iOS Simulator acceptance in both layouts**

Use the `build-ios-apps:ios-debugger-agent` skill. Select a booted iPhone 17 simulator; if none is booted, stop and ask the user to boot one as required by that skill. Build through the required slot wrapper:

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- xcodebuild build -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 17' -jobs 5 CODE_SIGNING_ALLOWED=NO
```

Then launch the already-built app through the simulator tooling and verify these exact observations in both standard and Experimental Player Layout:

1. Starting narration makes the card appear before model preparation.
2. Details expands and shows timestamped events in newest-first order.
3. The experimental layout visibly contains the same card.
4. A cached or real model preparation changes the summary through check/load/ready.
5. Rendering shows chapter, block count, voice, and progress.
6. Playing plus rendering shows both facts and a ready-ahead count.
7. A forced or observed queue gap says waiting, then records ready/resuming.
8. Pause says paused rather than waiting.
9. Render completion leaves the card visible while playback continues.
10. VoiceOver describes the collapsed state, progress, ready-ahead count, and Details expanded state.

Capture screenshots of collapsed and expanded cards in both layouts and capture unified logs filtered to category `NarrationStatus`. Confirm the logs contain numeric lifecycle metadata but no book title, source text, or file path. Report Simulator behavior separately from physical-device/model-download acceptance.

- [ ] **Step 8: Commit terminal cleanup and verified integration**

```bash
git add EchoCore/Services/Narration/NarrationState.swift EchoCore/Services/Narration/NarrationService.swift EchoCore/ViewModels/PlayerModel+Narration.swift EchoCore/ViewModels/PlayerModel.swift EchoTests/NarrationStateTests.swift EchoTests/NarrationServiceTests.swift EchoTests/PlayerModelTests.swift EchoTests/ArticleWorkshop/AnthologyChapterVoicesIntegrationTests.swift
git add -u
git commit -m "fix(narration): preserve terminal status diagnostics"
```

- [ ] **Step 9: Inspect the final diff and publish through the repository workflow**

Run:

```bash
git status --short --branch
git diff --check nightly...HEAD
git log --oneline nightly..HEAD
```

Expected: clean worktree, no whitespace errors, and coherent design/implementation commits. Push `codex/narration-status-verbosity`, open a ready PR to `nightly`, and report hosted CI as passing, failing, pending, or blocked without conflating it with Simulator or device acceptance.

## Final Acceptance Checklist

- [ ] Standard and experimental iOS layouts mount the same persistent narration card.
- [ ] Model delivery shows exact bytes and percent; cache hit, validation, load, and ready are distinct.
- [ ] Voice copy says selected/loaded, never downloaded.
- [ ] Rendering reports chapter/segment, voice, completed/total blocks, percentage, and elapsed no-update diagnostics.
- [ ] Playback, rendering, and buffer facts coexist in one summary.
- [ ] Ordinary pause, empty-buffer wait, automatic resume, render completion, and natural playback completion are distinguishable.
- [ ] Details shows the latest 200 timestamped events newest-first.
- [ ] Unified logs mirror lifecycle events without private book content or paths.
- [ ] Lock-screen subtitles update on discrete states, blocks, and five-percent download milestones.
- [ ] Slow synthesis is diagnostic but never automatically failed or cancelled.
- [ ] No silent Now Playing prewarm remains.
- [ ] Focused tests, full `make test`, Simulator smoke evidence, and hosted CI are reported separately.
