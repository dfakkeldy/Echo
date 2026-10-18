# Swift 6 Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate Echo's own Xcode targets to Swift 6 language mode without forcing third-party package dependencies into Swift 6 and without lowering concurrency safety.

**Architecture:** Keep the migration target-scoped: Echo app targets move to Swift 6 one at a time, while Swift Package dependencies keep their package-declared language modes. Clear concurrency diagnostics in small reviewer-friendly slices before the project setting flips. Use MainActor-default app isolation intentionally, and make non-UI pure helpers `nonisolated` only when they are demonstrably state-free or protected by their owning actor.

**Tech Stack:** Xcode 26.5, Swift 6 language mode, SwiftUI, Observation, Swift Concurrency, GRDB, WatchConnectivity, AVFoundation, ONNX Runtime, Swift Testing/XCTest through the existing Echo scheme.

## Global Constraints

- Open PRs against `nightly`, not `main`.
- Do not run two `xcodebuild` invocations concurrently; the local machine has an established single-build-slot convention.
- Use `make build-tests` once after code changes, then `make test-only FILTER=EchoTests/<SuiteName>` for focused test loops.
- Do not pass `SWIFT_VERSION=6.0` on the `xcodebuild` command line; that forces SwiftPM dependencies such as ZIPFoundation into Swift 6 and currently fails outside Echo-owned code.
- Do not introduce third-party frameworks.
- Do not replace Swift Concurrency with GCD; use `Task { @MainActor in updateState() }`, `Task.sleep(for:)`, actors, or `@concurrent` when that matches the work.
- Preserve current deployment targets during this migration: iOS `18.0`, macOS `15.0`, watchOS `11.0`. Any platform-floor increase is a separate product decision.
- Reconcile with `AGENTS.md`: `AGENTS.md:17` pins iOS 19 / macOS 16 / watchOS 12 — higher than the floors preserved above (this plan intentionally does NOT raise them; a platform-floor bump is a separate product decision), while `AGENTS.md:18` already mandates Swift 6, which this migration delivers. Either correct the stale `AGENTS.md` floors or record that the divergence is deliberate.
- Keep `SWIFT_APPROACHABLE_CONCURRENCY = YES` and `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` for app targets.
- Use `@Observable @MainActor` for shared UI-facing data; avoid `ObservableObject`, `@Published`, `@StateObject`, `@ObservedObject`, and `@EnvironmentObject` unless working in legacy integration code.

---

## Current Facts

- Current branch for this plan: `codex/swift-6-migration-plan`.
- Current app target language mode: `SWIFT_VERSION = 5.0`.
- Current effective Swift version for `Echo`, `Echo macOS`, and `Echo Watch App`: `5`.
- Current project settings already include `SWIFT_APPROACHABLE_CONCURRENCY = YES` and `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
- A global command-line `SWIFT_VERSION=6.0` build fails in `ZIPFoundation 0.9.20` due to package-owned global mutable vars. A SwiftPM dependency's language mode is governed by its own `Package.swift` tools-version / `swiftLanguageModes`, not by Echo's target settings — so the `SWIFT_VERSION=6.0` CLI override is what wrongly forces the packages. Echo must therefore migrate by editing Echo target build settings, never the command-line override.
- Several older audit findings have already been fixed or removed in this checkout: `Shared/AppGroupDefaults.swift` has `nonisolated static let suiteName`, `NarrationCache` is `nonisolated`, `KokoroFrontEnd` is `nonisolated`, `OnnxKokoroEngine.tensorData` is `nonisolated static`, and `NarrationExportService.swift` no longer exists.

## File Map

- `Echo Watch App/Services/WatchViewModel.swift`: make WatchConnectivity delegate callbacks safe under Swift 6 by marking framework callbacks `nonisolated` and hopping to MainActor before touching view-model state.
- `EchoCore/Services/WatchSyncManager.swift`: reference implementation for `nonisolated WCSessionDelegate` methods that enter `Task { @MainActor [weak self] in self?.syncToWatch() }`.
- `Echo macOS/Views/MacAnkiExportView.swift`: snapshot `selectedDeckIDs` and `decks` before unstructured tasks so `@Sendable` closures do not capture main-actor state directly.
- `EchoCore/Views/Bookmarks.swift`: replace timer-driven main-actor mutation with a cancellable `Task` loop using `Task.sleep(for:)`.
- `EchoCore/Services/Narration/ProgressFanOut.swift`: replay terminal progress to late subscribers and document the lock-protected `@unchecked Sendable` boundary.
- `EchoCore/Services/Narration/OnnxKokoroEngine.swift`: verify actor-owned front-end and prepare fan-out compile cleanly in Swift 6; keep CPU work off MainActor.
- `EchoCore/Services/Narration/KokoroFrontEnd.swift`: keep mutable caches actor-owned by `OnnxKokoroEngine`; do not make the type globally Sendable unless protected by an actor or lock.
- `EchoCore/Services/Narration/NarrationCache.swift`: keep `nonisolated` directory access.
- `EchoCore/Services/Export/AudioExportService.swift`: verify current `actor` export service compiles in Swift 6; do not resurrect removed `NarrationExportService`.
- `Echo.xcodeproj/project.pbxproj`: flip `SWIFT_VERSION` target-by-target, never through command-line override.

---

### Task 1: Migration Branch And Baseline

**Files:**
- Read: `Echo.xcodeproj/project.pbxproj`
- Read: `Makefile`
- Read: `CODE_AUDIT.md`
- Read: `docs/CODE_AUDIT_2026-06-13_session2.md`
- Read: `docs/CODE_AUDIT_2026-06-16_session4.md`
- Modify: none

**Interfaces:**
- Consumes: the current `nightly` branch state.
- Produces: a migration branch and a verified Swift 5 baseline that later tasks compare against.

- [ ] **Step 1: Create the implementation branch from `nightly`**

```bash
git fetch origin nightly
git switch nightly
git pull --ff-only origin nightly
git switch -c codex/swift-6-migration
```

Expected: the new branch is created from the latest `nightly`.

- [ ] **Step 2: Confirm target build settings before code changes**

Run each command separately:

```bash
xcodebuild -project Echo.xcodeproj -scheme Echo -configuration Debug -showBuildSettings | rg "EFFECTIVE_SWIFT_VERSION|SWIFT_VERSION|SWIFT_APPROACHABLE_CONCURRENCY|SWIFT_DEFAULT_ACTOR_ISOLATION|IPHONEOS_DEPLOYMENT_TARGET"
xcodebuild -project Echo.xcodeproj -scheme "Echo macOS" -configuration Debug -showBuildSettings | rg "EFFECTIVE_SWIFT_VERSION|SWIFT_VERSION|SWIFT_APPROACHABLE_CONCURRENCY|SWIFT_DEFAULT_ACTOR_ISOLATION|MACOSX_DEPLOYMENT_TARGET"
xcodebuild -project Echo.xcodeproj -scheme "Echo Watch App" -configuration Debug -showBuildSettings | rg "EFFECTIVE_SWIFT_VERSION|SWIFT_VERSION|SWIFT_APPROACHABLE_CONCURRENCY|SWIFT_DEFAULT_ACTOR_ISOLATION|WATCHOS_DEPLOYMENT_TARGET"
```

Expected: each scheme reports effective Swift version `5`, approachable concurrency `YES`, and MainActor default isolation.

- [ ] **Step 3: Build the current Swift 5 baseline**

```bash
make build-tests
```

Expected: `** TEST BUILD SUCCEEDED **`. If this fails before migration edits, stop and fix the existing baseline first.

- [ ] **Step 4: Capture a Swift 6 diagnostic baseline for the Echo target**

This sizes Task 5 with evidence instead of guesswork. Temporarily flip ONLY the `Echo` target to Swift 6 (scratch edit `SWIFT_VERSION = 6.0` for the Echo target's Debug config in `project.pbxproj` — do NOT pass it on the command line, do NOT commit), build for testing, count diagnostics, then revert:

```bash
make build-tests 2>&1 | tee /tmp/swift6-baseline.log
rg -c "error:|warning:" /tmp/swift6-baseline.log || true
git checkout -- Echo.xcodeproj/project.pbxproj   # discard the scratch flip
```

Expected: a concrete diagnostic count recorded before any migration commit. This only covers the iOS slice (the `Echo` scheme), so it is a floor, not a ceiling. If the count is large across `EchoCore`/`Shared`, split Task 5 into reviewer-sized commits by subsystem instead of one `EchoCore Shared` blob.

- [ ] **Step 5: Commit only if baseline documentation was added**

If no files changed, skip the commit. If a migration note file was added by the implementer, commit only that file:

```bash
git add docs/superpowers/plans/2026-06-25-swift-6-migration.md
git commit -m "docs: add Swift 6 migration plan"
```

Expected: either no commit is needed, or the commit contains documentation only.

---

### Task 2: WatchConnectivity Delegate Isolation

**Files:**
- Modify: `Echo Watch App/Services/WatchViewModel.swift`
- Reference: `EchoCore/Services/WatchSyncManager.swift:140`

**Interfaces:**
- Consumes: `WatchViewModel.requestCurrentState()` and `WatchViewModel.applyState(_:)`, both MainActor-isolated through the view model.
- Produces: `WatchViewModel` delegate methods that are callable by WatchConnectivity from non-main delivery queues without touching MainActor state directly.

- [ ] **Step 1: Update activation completion**

In `Echo Watch App/Services/WatchViewModel.swift`, replace the activation delegate with this shape:

```swift
nonisolated func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
) {
    guard activationState == .activated else {
        if let error {
            logger.error("WatchConnectivity activation failed: \(error)")
        }
        return
    }

    Task { @MainActor [weak self] in
        self?.requestCurrentState()
    }
}
```

Expected: the method no longer calls `requestCurrentState()` directly from the delegate callback.

- [ ] **Step 2: Update reachability**

Replace the reachability delegate with:

```swift
nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
    guard session.isReachable else { return }

    Task { @MainActor [weak self] in
        self?.requestCurrentState()
    }
}
```

Expected: `session.isReachable` is read before the actor hop, and view-model state is touched only inside the MainActor task.

- [ ] **Step 3: Update application context and messages**

Use the same nonisolated delegate shape for the remaining incoming payload methods:

```swift
nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
    guard session.activationState == .activated else { return }

    Task { @MainActor [weak self] in
        self?.applyState(applicationContext)
    }
}

nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
    guard session.activationState == .activated else { return }

    Task { @MainActor [weak self] in
        self?.applyState(message)
    }
}

nonisolated func session(
    _ session: WCSession,
    didReceiveMessage message: [String: Any],
    replyHandler: @escaping ([String: Any]) -> Void
) {
    guard session.activationState == .activated else {
        replyHandler([:])
        return
    }

    Task { @MainActor [weak self] in
        self?.applyState(message)
        replyHandler(["handled": true])
    }
}

nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
    guard session.activationState == .activated else { return }

    Task { @MainActor [weak self] in
        self?.applyState(userInfo)
        self?.requestCurrentState()
    }
}
```

Expected: every `WCSessionDelegate` entry point that touches `WatchViewModel` state first hops to MainActor.

- [ ] **Step 4: Run the watch build**

```bash
xcodebuild -project Echo.xcodeproj -scheme "Echo Watch App" -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Expected: `** BUILD SUCCEEDED **`. The direct `[String: Any]` -> `Task { @MainActor in }` capture is expected to compile under Swift 6 region-based isolation (the same shape already ships in `WatchSyncManager`), so the `WatchStateSnapshot: Sendable` refactor is a fallback, not the default path — only extract it if the build actually reports a `[String: Any]` Sendable-capture diagnostic.

> Out of scope (track separately): the outbound `sendMessage` reply/error closures in `requestCurrentState()` (~:590) and `sendCommand()` (~:630) call MainActor methods and are invoked off-main by WatchConnectivity — a pre-existing latent runtime race. It is NOT a Swift 6 compile blocker (those blocks import non-`@Sendable` and inherit MainActor isolation), so this migration deliberately leaves them; do not "fix" them as part of the flip.

- [ ] **Step 5: Commit**

```bash
git add "Echo Watch App/Services/WatchViewModel.swift"
git commit -m "fix(watch): isolate WCSession delegate callbacks for Swift 6"
```

Expected: one commit with only `WatchViewModel.swift`.

---

### Task 3: MainActor Capture Cleanup

**Files:**
- Modify: `Echo macOS/Views/MacAnkiExportView.swift`
- Modify: `EchoCore/Views/Bookmarks.swift`

**Interfaces:**
- Consumes: `MacApkgExportService.export(deckIDs:db:)`, `dbService.readAsync`, and `VoiceMemoRecorder`.
- Produces: task bodies that operate on immutable Sendable snapshots instead of directly reading MainActor SwiftUI state from `@Sendable` closures.

- [ ] **Step 1: Snapshot macOS deck export state before `Task`**

In `MacAnkiExportView.exportToFile()` (there is no `exportToApkg()`), capture immutable values before creating the task. Keep the enclosing AppKit save-panel closure: the snippet's `url` is `panel.url`, in scope only inside `panel.begin { response in … }`.

```swift
let selectedDeckIDsSnapshot = selectedDeckIDs
let writer = dbService.writer

Task {
    do {
        let service = MacApkgExportService()
        let apkgURL = try await service.export(
            deckIDs: Array(selectedDeckIDsSnapshot),
            db: writer
        )
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: apkgURL, to: url)
        try? FileManager.default.removeItem(at: apkgURL)

        await MainActor.run {
            exportPath = url.path
            isExporting = false
        }
    } catch {
        await MainActor.run {
            exportError = error.localizedDescription
            isExporting = false
        }
    }
}
```

Expected: the task uses `selectedDeckIDsSnapshot` and `writer`, not live SwiftUI state.

- [ ] **Step 2: Snapshot AnkiConnect state before `Task`**

In `MacAnkiExportView.sendToAnkiConnect()`, capture immutable values before creating the task:

```swift
let selectedDeckIDsSnapshot = selectedDeckIDs
let decksSnapshot = decks
let writer = dbService.writer

Task {
    do {
        let cards: [Flashcard] = try await dbService.readAsync { db in
            var allCards: [Flashcard] = []
            for deckID in selectedDeckIDsSnapshot {
                let deckCards = try Flashcard
                    .filter(Column("deck_id") == deckID)
                    .fetchAll(db)
                allCards.append(contentsOf: deckCards)
            }
            return allCards
        }

        guard !cards.isEmpty else {
            await MainActor.run {
                exportError = "No flashcards found in selected decks"
                isExporting = false
            }
            return
        }

        var deckNames: [String: String] = [:]
        for deckID in selectedDeckIDsSnapshot {
            if let deck = decksSnapshot.first(where: { $0.id == deckID }) {
                deckNames[deckID] = deck.name
            }
        }

        let bridge = AnkiConnectBridge()
        try await bridge.addCards(cards: cards, deckNames: deckNames)

        await MainActor.run {
            exportPath = "Sent to Anki successfully (\(cards.count) cards)"
            isExporting = false
            ankiStatusMessage = "Sent \(cards.count) cards to Anki"
        }
    } catch {
        await MainActor.run {
            exportError = error.localizedDescription
            isExporting = false
        }
    }
}
```

Expected: no direct `selectedDeckIDs` or `decks` reads occur inside the task body.

- [ ] **Step 3: Remove unused snapshot values after compiling**

If `writer` is not used after the edit because `dbService.readAsync` still owns the database access, remove the unused `let writer = dbService.writer` line. Keep the immutable deck snapshots.

Run:

```bash
xcodebuild -project Echo.xcodeproj -scheme "Echo macOS" -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Expected: `** BUILD SUCCEEDED **` and no unused-local warning from `writer`.

- [ ] **Step 4: Replace the Bookmarks timer with a cancellable task**

In `EchoCore/Views/Bookmarks.swift`, replace the timer state:

```swift
@State private var elapsedTask: Task<Void, Never>?
```

Replace the timer setup inside `beginRecording()`:

```swift
elapsedTask?.cancel()
elapsedTask = Task { @MainActor in
    while !Task.isCancelled {
        do {
            try await Task.sleep(for: .milliseconds(200))
        } catch {
            return
        }
        guard recorder?.isRecording == true else { return }
        elapsed += 0.2
    }
}
```

Replace `stopElapsedTimer()` with:

```swift
private func stopElapsedTimer() {
    elapsedTask?.cancel()
    elapsedTask = nil
}
```

Expected: no `Timer.scheduledTimer` closure mutates SwiftUI state; the task is cancelled on save/discard paths that already call `stopElapsedTimer()`.

- [ ] **Step 5: Build iOS tests**

```bash
make build-tests
```

Expected: `** TEST BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add "Echo macOS/Views/MacAnkiExportView.swift" EchoCore/Views/Bookmarks.swift
git commit -m "fix(concurrency): snapshot UI state before tasks"
```

Expected: one commit with only the two capture-cleanup files.

---

### Task 4: Narration Isolation And Progress Fan-Out

**Files:**
- Modify: `EchoCore/Services/Narration/ProgressFanOut.swift`
- Read: `EchoCore/Services/Narration/OnnxKokoroEngine.swift`
- Read: `EchoCore/Services/Narration/KokoroFrontEnd.swift`
- Read: `EchoCore/Services/Narration/NarrationCache.swift`
- Read: `EchoCore/Services/Export/AudioExportService.swift`
- Test: existing narration tests under `EchoTests`

**Interfaces:**
- Consumes: `NarrationPrepareProgress`, `OnnxKokoroEngine.prepare(progress:)`, and `TTSEngine`.
- Produces: a fan-out helper that keeps its `@unchecked Sendable` boundary defensible and a narration engine slice that compiles under Swift 6 without moving heavy synthesis work onto MainActor.

- [ ] **Step 1: Add terminal replay to `ProgressFanOut`**

Replace `ProgressFanOut` with this implementation:

```swift
nonisolated final class ProgressFanOut: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [@Sendable (NarrationPrepareProgress) -> Void] = []
    private var terminalProgress: NarrationPrepareProgress?

    func add(_ subscriber: @escaping @Sendable (NarrationPrepareProgress) -> Void) {
        let replay: NarrationPrepareProgress?
        lock.lock()
        if let terminalProgress {
            replay = terminalProgress
        } else {
            subscribers.append(subscriber)
            replay = nil
        }
        lock.unlock()

        if let replay {
            subscriber(replay)
        }
    }

    func emit(_ progress: NarrationPrepareProgress) {
        let current: [@Sendable (NarrationPrepareProgress) -> Void]
        lock.lock()
        if progress == .ready {
            terminalProgress = progress
        }
        current = subscribers
        lock.unlock()

        for subscriber in current {
            subscriber(progress)
        }
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        subscribers.removeAll()
    }
}
```

Expected: a late subscriber added after `.ready` immediately receives `.ready`.

> Reality check: on the current `OnnxKokoroEngine` wiring this replay branch is unreachable — a post-ready caller takes the `session != nil` fast path (`OnnxKokoroEngine.swift:121`, direct `progress(.ready)`), and the join path already re-emits `progress(.ready)` after `await task.value`. So treat this change as defensive hardening of `ProgressFanOut`, NOT as a fix for an engine-observable "stale spinner" race. The load-bearing part of this slice is the Swift 6 `@unchecked Sendable` isolation boundary, not the replay. Add a `ProgressFanOut` unit test that subscribes after `.ready` and asserts immediate delivery.

- [ ] **Step 2: Verify `OnnxKokoroEngine` helper isolation is deliberate**

Confirm the current code has these properties:

```swift
actor OnnxKokoroEngine: TTSEngine
nonisolated final class KokoroFrontEnd
nonisolated enum NarrationCache
private nonisolated static func tensorData<T>(_ array: [T]) -> NSMutableData
```

Expected: the engine remains an actor, pure/static helpers stay nonisolated, and mutable front-end caches remain actor-owned through the engine's private `frontEnd`.

- [ ] **Step 3: Run narration-focused tests**

Run the narrow suites that exist in this checkout:

```bash
make build-tests
# 'EchoTests/Narration' is not a real umbrella suite — discover the actual suites and run each:
find EchoTests -name '*Narration*Tests.swift' -maxdepth 2
# then, per suite: make test-only FILTER=EchoTests/<SuiteName>
```

Expected: `make build-tests` succeeds. If `EchoTests/Narration` is not a valid filter in this checkout, run the available narration-named suites listed by:

```bash
find EchoTests -name '*Narration*Tests.swift' -maxdepth 2
```

and then run each suite with `make test-only FILTER=EchoTests/<SuiteName>`.

- [ ] **Step 4: Commit**

```bash
git add EchoCore/Services/Narration/ProgressFanOut.swift
git commit -m "fix(narration): replay terminal prepare progress"
```

Expected: one commit with only `ProgressFanOut.swift` unless Swift 6 diagnostics in this task required a small narration isolation edit.

---

### Task 5: Echo And EchoTests Swift 6 Flip

**Files:**
- Modify: `Echo.xcodeproj/project.pbxproj`
- Modify: Swift files surfaced by the first Echo-target Swift 6 compile
- Test: `EchoTests`

**Interfaces:**
- Consumes: Tasks 2 through 4.
- Produces: the iOS app and unit-test targets compiling in Swift 6 language mode.

- [ ] **Step 1: Change only Echo app/test target build settings**

In Xcode or by editing `Echo.xcodeproj/project.pbxproj`, set `SWIFT_VERSION = 6.0` for the Debug and Release build configurations that belong to:

```text
Echo
EchoTests
EchoUITests
```

Do not change SwiftPM package settings. Do not run `xcodebuild -project Echo.xcodeproj -scheme Echo SWIFT_VERSION=6.0 build`.

Expected verification command:

```bash
xcodebuild -project Echo.xcodeproj -scheme Echo -configuration Debug -showBuildSettings | rg "TARGET_NAME|EFFECTIVE_SWIFT_VERSION|SWIFT_VERSION"
```

Expected: Echo-owned targets show effective Swift version `6`; package targets are not forced by command-line override.

- [ ] **Step 2: Build for testing**

```bash
make build-tests
```

Expected: either `** TEST BUILD SUCCEEDED **` or Swift 6 diagnostics in Echo-owned source files. If diagnostics appear, fix them by pattern:

```swift
// Mutable captured var in a Sendable closure:
let anchorsToSave = anchors
try await db.write { db in
    try AlignmentAnchorDAO(db: db).insertAll(anchorsToSave)
}

// MainActor state needed inside a task:
let deckIDs = Array(selectedDeckIDs)
Task {
    await MainActor.run {
        ankiStatusMessage = "Preparing \(deckIDs.count) decks"
    }
}

// UI mutation after async work:
await MainActor.run {
    isExporting = false
}

// Pure helper inferred MainActor under default isolation:
nonisolated static func isUtilityCallout(_ text: String) -> Bool {
    let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
    return ["tip", "warning", "note", "caution", "important"].contains(lower)
}
```

Expected: each fix removes a warning/error without adding `nonisolated(unsafe)` or `@unchecked Sendable`.

- [ ] **Step 3: Run the unit-test scheme**

```bash
make test
```

Expected: `TEST SUCCEEDED`. If unrelated pre-existing tests fail, capture the failing suite names and rerun them individually after confirming the failure also occurs on the pre-migration parent commit.

- [ ] **Step 4: Commit**

```bash
git add Echo.xcodeproj/project.pbxproj EchoCore Shared EchoTests EchoUITests
git commit -m "build: migrate iOS targets to Swift 6"
```

Expected: one commit containing the project setting flip and only the source edits required for Echo/EchoTests Swift 6 compilation.

---

### Task 6: Widget And Watch Swift 6 Flip

**Files:**
- Modify: `Echo.xcodeproj/project.pbxproj`
- Modify: `Echo Widget/Models/AppIntent.swift` only if Swift 6 diagnostics reappear
- Modify: `Echo Watch App/Services/WatchViewModel.swift` only if Swift 6 diagnostics remain after Task 2 (expect them — the file's own `Timer.scheduledTimer` + `MainActor.assumeIsolated` closures at ~:177, :857, :905, :927 and the rollback timer at ~:165 are NOT covered by Task 2 and may need the same `Task { @MainActor in }` treatment)
- Test: watch and widget schemes

**Interfaces:**
- Consumes: Task 5 project settings pattern.
- Produces: widget and watch targets compiling in Swift 6 language mode.

- [ ] **Step 1: Flip widget target settings**

Set `SWIFT_VERSION = 6.0` for Debug and Release build configurations that belong to:

```text
Echo WidgetExtension
```

Run:

```bash
xcodebuild -project Echo.xcodeproj -target "Echo WidgetExtension" -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Expected: `** BUILD SUCCEEDED **`. If `AppIntent.perform()` diagnostics appear, preserve the existing fixed pattern by keeping the intent methods MainActor-isolated.

- [ ] **Step 2: Commit widget flip**

```bash
git add Echo.xcodeproj/project.pbxproj "Echo Widget"
git commit -m "build: migrate widget target to Swift 6"
```

Expected: one widget-focused commit.

- [ ] **Step 3: Flip watch target settings**

Set `SWIFT_VERSION = 6.0` for Debug and Release build configurations that belong to:

```text
Echo Watch App
Echo Watch AppTests
Echo Watch AppUITests
```

Run:

```bash
xcodebuild -project Echo.xcodeproj -scheme "Echo Watch App" -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Expected: `** BUILD SUCCEEDED **`. If WatchConnectivity payload Sendable diagnostics appear, convert each `[String: Any]` payload into a typed Sendable snapshot before the MainActor task.

- [ ] **Step 4: Commit watch flip**

```bash
git add Echo.xcodeproj/project.pbxproj "Echo Watch App" "Echo Watch AppTests" "Echo Watch AppUITests"
git commit -m "build: migrate watch targets to Swift 6"
```

Expected: one watch-focused commit.

---

### Task 7: macOS And CLI Swift 6 Flip

**Files:**
- Modify: `Echo.xcodeproj/project.pbxproj`
- Modify: `Echo macOS/Views/MacAnkiExportView.swift` only if Swift 6 diagnostics remain after Task 3
- Modify: `Tools/echo-cli/add-target.rb` if new target scaffolding should default to Swift 6 after the migration
- Test: `Echo macOS` and `echo-cli` schemes

**Interfaces:**
- Consumes: Tasks 3 and 5.
- Produces: macOS app and CLI targets compiling in Swift 6 language mode.

- [ ] **Step 1: Flip macOS target settings**

Set `SWIFT_VERSION = 6.0` for Debug and Release build configurations that belong to:

```text
Echo macOS
```

Run:

```bash
xcodebuild -project Echo.xcodeproj -scheme "Echo macOS" -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Commit macOS flip**

```bash
git add Echo.xcodeproj/project.pbxproj "Echo macOS"
git commit -m "build: migrate macOS target to Swift 6"
```

Expected: one macOS-focused commit.

- [ ] **Step 3: Flip CLI target settings**

Set `SWIFT_VERSION = 6.0` for Debug and Release build configurations that belong to:

```text
echo-cli
```

Update `Tools/echo-cli/add-target.rb` so future generated CLI targets use Swift 6 (cosmetic / forward-looking only — this one-shot scaffolder is stale: it still references a non-existent `Tools/echo-cli/main.swift` and aborts on re-run, and the live CLI entry point is `EchoCLI.swift`. Do NOT run the script; the load-bearing flip is the `project.pbxproj` change above):

```ruby
bs['SWIFT_VERSION'] = '6.0'
```

Run:

```bash
xcodebuild -project Echo.xcodeproj -scheme echo-cli -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit CLI flip**

```bash
git add Echo.xcodeproj/project.pbxproj Tools/echo-cli/add-target.rb
git commit -m "build: migrate echo-cli to Swift 6"
```

Expected: one CLI-focused commit.

---

### Task 8: Strict Concurrency Project Hygiene

**Files:**
- Modify: `Echo.xcodeproj/project.pbxproj`
- Modify: Swift files only if explicit strict-concurrency diagnostics remain

**Interfaces:**
- Consumes: all target flips.
- Produces: explicit strict concurrency checking for Echo-owned targets, making future regressions visible.

- [ ] **Step 1: Add explicit strict concurrency settings**

For each Echo-owned target build configuration now using Swift 6, add or verify:

```text
SWIFT_STRICT_CONCURRENCY = complete;
```

Keep:

```text
SWIFT_APPROACHABLE_CONCURRENCY = YES;
SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor;
```

Expected: project settings make strict concurrency an explicit target policy rather than an implicit language-mode side effect.

- [ ] **Step 2: Verify all Echo-owned targets**

Run these one at a time:

```bash
make build-tests
make test
xcodebuild -project Echo.xcodeproj -target "Echo WidgetExtension" -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Echo.xcodeproj -scheme "Echo Watch App" -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Echo.xcodeproj -scheme "Echo macOS" -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Echo.xcodeproj -scheme echo-cli -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
# Compile the Swift-6-flipped test targets that have no host-app run of their own:
xcodebuild build-for-testing -project Echo.xcodeproj -scheme "Echo Watch App" -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO
```

Expected: all commands succeed. If a command fails due signing despite `CODE_SIGNING_ALLOWED=NO`, rerun that command for a simulator or generic destination that does not require provisioning. Any flipped test target not built above (e.g. `EchoUITests`, `Echo Watch AppUITests` if excluded from their scheme's build/test action) is Swift-6-unverified — build it via `-target` or call out in the PR that it is unchecked.

- [ ] **Step 3: Run SwiftLint if installed**

```bash
if command -v swiftlint >/dev/null 2>&1; then swiftlint; else echo "SwiftLint not installed"; fi
```

Expected: either no SwiftLint warnings/errors, or `SwiftLint not installed`.

- [ ] **Step 4: Commit strict concurrency hygiene**

```bash
git add Echo.xcodeproj/project.pbxproj EchoCore Shared "Echo Watch App" "Echo Widget" "Echo macOS" Tools
git commit -m "build: enforce strict concurrency for Swift 6 targets"
```

Expected: one final migration hygiene commit.

---

### Task 9: Final Audit And PR Prep

**Files:**
- Modify: `ARCHITECTURE.md` — unconditionally refresh the "Swift Concurrency & Thread Safety" section (~:915) to describe the new per-target Swift 6 language mode + strict-concurrency posture (the existing `nonisolated(unsafe)` / `@preconcurrency` notes become incomplete, not wrong). Also update the generated source-tree sections if files were added or removed.
- Modify: `CHANGELOG.md` — add a migration entry (Swift 6 language mode for Echo-owned targets).
- Check: `ROADMAP.md` for a "Swift 6 migration" item to mark done.
- Modify: release notes only if project convention requires migration notes for internal reviewers

**Interfaces:**
- Consumes: all previous commits.
- Produces: a ready PR against `nightly` with clear verification evidence.

- [ ] **Step 1: Confirm all target language modes**

Run each command separately:

```bash
xcodebuild -project Echo.xcodeproj -scheme Echo -configuration Debug -showBuildSettings | rg "TARGET_NAME|EFFECTIVE_SWIFT_VERSION|SWIFT_VERSION"
xcodebuild -project Echo.xcodeproj -target "Echo WidgetExtension" -configuration Debug -showBuildSettings | rg "TARGET_NAME|EFFECTIVE_SWIFT_VERSION|SWIFT_VERSION"
xcodebuild -project Echo.xcodeproj -scheme "Echo Watch App" -configuration Debug -showBuildSettings | rg "TARGET_NAME|EFFECTIVE_SWIFT_VERSION|SWIFT_VERSION"
xcodebuild -project Echo.xcodeproj -scheme "Echo macOS" -configuration Debug -showBuildSettings | rg "TARGET_NAME|EFFECTIVE_SWIFT_VERSION|SWIFT_VERSION"
xcodebuild -project Echo.xcodeproj -scheme echo-cli -configuration Debug -showBuildSettings | rg "TARGET_NAME|EFFECTIVE_SWIFT_VERSION|SWIFT_VERSION"
```

Expected: Echo-owned targets report effective Swift version `6`. SwiftPM dependencies are not migrated by command-line override.

- [ ] **Step 2: Run final verification**

Run these one at a time:

```bash
make build-tests
make test
xcodebuild -project Echo.xcodeproj -target "Echo WidgetExtension" -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Echo.xcodeproj -scheme "Echo Watch App" -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Echo.xcodeproj -scheme "Echo macOS" -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Echo.xcodeproj -scheme echo-cli -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
if command -v swiftlint >/dev/null 2>&1; then swiftlint; else echo "SwiftLint not installed"; fi
```

Expected: all builds and tests pass, and SwiftLint is either clean or absent.

- [ ] **Step 3: Inspect the final diff**

```bash
git status --short
git diff --stat origin/nightly..HEAD
git log --oneline origin/nightly..HEAD
```

Expected: the diff contains migration commits only: concurrency fixes, Swift version build settings, and associated tests/docs.

- [ ] **Step 4: Open the PR against `nightly`**

Use the repository's normal PR workflow. PR summary:

```markdown
## Summary
- migrated Echo-owned targets to Swift 6 language mode target-by-target
- fixed Swift 6 concurrency blockers in watch callbacks, UI task captures, and narration progress fan-out
- made strict concurrency explicit for migrated targets

## Verification
- make build-tests
- make test
- xcodebuild -project Echo.xcodeproj -target "Echo WidgetExtension" -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
- xcodebuild -project Echo.xcodeproj -scheme "Echo Watch App" -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build
- xcodebuild -project Echo.xcodeproj -scheme "Echo macOS" -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
- xcodebuild -project Echo.xcodeproj -scheme echo-cli -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
- swiftlint, if installed
```

Expected: PR target is `nightly`.

---

## Self-Review

- Spec coverage: the plan covers baseline, known concurrency blockers, narration isolation, target-scoped Swift 6 flips, strict concurrency, and final verification.
- Placeholder scan: no open placeholders are left; conditional branches include concrete fallback actions.
- Type consistency: `selectedDeckIDsSnapshot`, `decksSnapshot`, `elapsedTask`, `ProgressFanOut.add(_:)`, and `NarrationPrepareProgress.ready` are used consistently across tasks.
- Scope check: this is one migration project. Platform floor changes and dependency upgrades are intentionally outside this plan unless a target-specific Swift 6 diagnostic requires them. Pre-existing *runtime* races that are not Swift 6 compile blockers are also out of scope — notably `ContinuousAlignmentService.stop()`'s untracked `WhisperSession.shared.release()` task (`CODE_AUDIT.md` §3.4); track it separately rather than fixing it under the flip.

## Execution Choice

Plan complete and saved to `docs/superpowers/plans/2026-06-25-swift-6-migration.md`. Two execution options:

1. **Subagent-Driven (recommended)** - dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** - execute tasks in this session using executing-plans, batch execution with checkpoints.
