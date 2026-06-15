# CODE_AUDIT.md Remediation Plan

**Branch:** `feat/code-audit-remediation`
**Generated:** 2026-06-09
**Source:** CODE_AUDIT.md (34 actionable findings + 5 cross-cutting recommendations)
**Already fixed:** §3.1 (WhisperSession race → ModelRetainBox), §6.1 (Zip-slip → safeDestination)

---

## Implementation Order (overnight batch)

Findings are grouped into 4 phases by effort, risk, and dependencies.
Each item lists exact file:line, the change, and a Conventional Commit message.

---

## Phase 1: Quick Wins (~2 hours, 12 commits)

All are independent, safe, and committable individually. Do these first —
they clear the deck and build momentum.

### 1.1 Fix display-name typo "Audiobookk"

**Files:**
- `Echo.xcodeproj/project.pbxproj:709`
- `Echo.xcodeproj/project.pbxproj:751`

**Change:** `"Echo: Audiobookk Study Player"` → `"Echo: Audiobook Study Player"` (both Debug and Release for Echo macOS target)

**Commit:** `fix: correct "Audiobookk" typo in macOS bundle display name`

---

### 1.2 Replace bare print() with Logger

**File:** `EchoCore/Views/SettingsView.swift:313-319`

**Before:**
```swift
UIApplication.shared.setAlternateIconName(iconName) { error in
    if let error = error {
        print("Failed to change app icon: \(error.localizedDescription)")
    } else {
        currentIcon = iconName
    }
}
```

**After:**
```swift
UIApplication.shared.setAlternateIconName(iconName) { [weak self] error in
    if let error = error {
        Logger(category: "Settings").error("Failed to change app icon: \(error.localizedDescription)")
    } else {
        Task { @MainActor [weak self] in
            self?.currentIcon = iconName
        }
    }
}
```

**Notes:** Also fixes §8.3 (missing @MainActor hop on state mutation). The completion
handler's delivery queue is undocumented; wrapping in `Task { @MainActor }` makes it
compiler-checked. Import `os.log` if not already present.

**Commit:** `fix: replace print() with Logger and add @MainActor hop in app-icon completion`

---

### 1.3 Extract "TranscriptDidUpdate" notification name literal

**Files:**
- `Echo macOS/Views/TranscriptStore.swift:29`
- `Echo macOS/Views/TranscriptionManager.swift:184`
- `Echo macOS/Views/TranscriptionManager.swift:255`

Search for all occurrences first:
```bash
grep -rn '"TranscriptDidUpdate"' Echo*
```

**Change:** Add to `EchoCore/Services/NotificationNames.swift` (or create if absent):
```swift
extension Notification.Name {
    static let transcriptDidUpdate = Notification.Name("TranscriptDidUpdate")
}
```

Replace all string literals with `.transcriptDidUpdate`.

**Commit:** `refactor: extract "TranscriptDidUpdate" notification name to constant`

---

### 1.4 Move model enums out of Services/

**Files to move:**
- `EchoCore/Services/LoopMode.swift` → `EchoCore/Models/LoopMode.swift`
- `EchoCore/Services/SleepTimerMode.swift` → `EchoCore/Models/SleepTimerMode.swift`

**Files to update (imports):** Search for all references:
```bash
grep -rn "LoopMode\|SleepTimerMode" EchoCore/ Echo* Watch*/ Shared/ --include="*.swift"
```

Update all import references. These are pure enums with no service dependencies.

**Commit:** `refactor: move LoopMode and SleepTimerMode enums to Models/`

---

### 1.5 Fix stale CLAUDE.md project context

**File:** `CLAUDE.md:9`

**Current:** References "SwiftUI CLI" in `Tools/` which was deleted in commit `751e89c`.

**Change:** Update the Tools description to reflect the current state:
- The `EchoTranscriptionCLI` and `OrbitTranscriptionCLI` were removed
- Alignment is now entirely in-app via WhisperKit
- The `Tools/` directory contains `transcription_generator.py` (Python pipeline) and its cache artifacts

**Commit:** `docs: update CLAUDE.md Tools description to reflect current state`

---

### 1.6 Delete empty rebrand leftover directories

**Commands:**
```bash
git rm -r OrbitAudioBooks/
git rm -r "Orbit Audiobooks macOS/"
```

Verified: zero references in `project.pbxproj` (`grep -c "OrbitAudioBooks" Echo.xcodeproj/project.pbxproj` returns 0).

**Commit:** `chore: remove empty Orbit-branded directory stubs`

---

### 1.7 Untrack scratch/ and build artifacts

**Commands:**
```bash
# Move anything worth keeping to docs/
mkdir -p docs/design-notes
cp scratch/NowPlayingTab_before.swift docs/design-notes/
cp scratch/NowPlayingTab_after.swift docs/design-notes/
# Then untrack
git rm -r scratch/
```

Add to `.gitignore`:
```
# Build artifacts
build.log

# Python cache
__pycache__/
```

Delete untracked leftovers:
```bash
rm -rf Tools/OrbitTranscriptionCLI/
rm -rf Tools/__pycache__/
```

**Commit:** `chore: untrack scratch/ directory, add build.log and __pycache__ to .gitignore`

---

### 1.8 DatabaseService migration registration (minor fix)

**File:** `Shared/Database/DatabaseService.swift` (migration registration)

The audit noted this was fixed in a prior round but worth verifying: `runMigrations(writer:)` should be `nonisolated` and schema migrate methods should not require main-actor isolation.

Verify by reading and confirming no `MainActor.assumeIsolated` remains in migration closures.

**Commit:** (if needed) `fix: remove MainActor.assumeIsolated from database migration closures`

---

## Phase 2: Critical + High Priority (~4 hours, 4-5 commits)

### 2.1 Fix macOS target build (CRITICAL)

**Root cause A — WhisperKit not linked:** `MacGlobalAlignmentService.swift:4` imports WhisperKit,
but the macOS target doesn't link it. The iOS target links WhisperKit at `project.pbxproj:220`
(Frameworks phase). The macOS target needs the same.

**Root cause B — Orphaned shell phase:** `project.pbxproj:577-601` ("Build and Copy OrbitTranscriptionCLI")
runs `swift build` against `Tools/OrbitTranscriptionCLI/`, which was deleted from git in `751e89c`.
This phase has `alwaysOutOfDate = 1` and `set -euo pipefail`, so it fails every build.

**Root cause C — Missing entitlement:** `Echo macOS/Echo_macOS.entitlements` lacks the
`group.com.echo.audiobooks` app group, so `AppGroupDefaults` hits `assertionFailure` at
`Shared/AppGroupDefaults.swift:11-13`.

**Decision needed:** Revive or park the macOS target?
- **Revive:** 3 fixes below + move shared logic from Mac* services into Shared/
- **Park:** Remove scheme + target + all Mac* files + document in README

**If reviving — Fix A:** In Xcode: add WhisperKit framework to Echo macOS target's
"Frameworks, Libraries, and Embedded Content" build phase. This edits project.pbxproj
to add a `PBXBuildFile` entry linking `WhisperKit` to the macOS target (mirroring line 15
which links it to the iOS target).

**Fix B:** Delete the shell phase. In `project.pbxproj`:
1. Remove `AA0100000000000000000033 /* Build and Copy OrbitTranscriptionCLI */` from
   the macOS target's `buildPhases` array (line 303)
2. Remove the entire `AA0100000000000000000033` section (lines 577-601)

**Fix C:** Add to `Echo macOS/Echo_macOS.entitlements`:
```xml
<key>com.apple.security.application-groups</key>
<array>
    <string>group.com.echo.audiobooks</string>
</array>
```

**Also fix:** The display-name typo from Phase 1.1 (same lines).

**Commit:** `fix: revive macOS target — link WhisperKit, remove orphaned shell phase, add app-group entitlement`

---

### 2.2 GRDB main-actor synchronous work — categorize + convert hot paths (HIGH)

**23 sites found:**

| Category | File | Lines | Action |
|----------|------|-------|--------|
| **HOT — playback tick** | `InlineFlashcardTriggerController.swift` | 54, 94 | Convert to async read/write |
| **HOT — playback tick** | `PlaybackTimelineService.swift` | 61, 63 | Convert to async read |
| **HOT — UI gesture** | `PlayerTimelinePersistenceService.swift` | 16 | Convert to async read |
| **WARM — load** | `ChapterLoadingCoordinator.swift` | 135, 136 | Convert to async write |
| **WARM — load** | `TimelineIngestionService.swift` | 31, 44, 45, 69, 70, 91, 101, 105, 121, 122 | Keep sync (import-time batch) |
| **COLD — scroll** | `TimelineService.swift` | 140, 178 | Convert to async read/write |
| **COLD — event log** | `PlaybackEventLogger.swift` | 20, 46, 67 | Keep sync (fire-and-forget logging) |
| **COLD — import** | `EPUBImportService.swift` | 248 | Keep sync |

**Strategy:** Don't convert all 23 at once. Focus on the 6 HOT sites first:

**For `InlineFlashcardTriggerController`:** This runs during playback ticks. Change to:
```swift
// Before (sync, blocks main thread)
cachedTrackFlashcards = try FlashcardDAO(db: db.writer).flashcards(for: trackKey)

// After (async, non-blocking)
cachedTrackFlashcards = try await db.writer.read { db in
    try FlashcardDAO(db: db).flashcards(for: trackKey)
}
```

The calling method (`checkTrigger`, called from `PlaybackController`'s time-update delegate)
must become async or spawn a Task. Since `PlaybackController` is `@MainActor`, spawn a
detached task for the DB read.

**For `PlaybackTimelineService`:** Same pattern — convert to `db.writer.read { }`.

**DAO-layer policy (cross-cutting §10 recommendation #2):**
Add async variants to DAO protocols:
```swift
protocol EPubBlockDAOProtocol {
    func visibleBlocks(for audiobookID: String) throws -> [EPubBlockRecord]  // existing sync
    func visibleBlocks(for audiobookID: String) async throws -> [EPubBlockRecord]  // new async
}
```

Default implementation in the DAO extension using `db.writer.read { }`.

**Commit:** `perf: convert hot-path GRDB reads to async to avoid main-thread blocking`

---

### 2.3 Dead directory and file cleanup (HIGH)

Already partially covered by Phase 1.6 and 1.7. Additional items:

**Delete the architect scaffold:**
```bash
git rm EchoCore/Views/AudiobookPlayerUIArchitect.swift
git rm add_architect.rb
```

Verified: zero references to `AudiobookPlayerUIArchitect` in any source file.

**Commit:** `chore: remove AudiobookPlayerUIArchitect design scaffold and companion Ruby script`

---

## Phase 3: Medium Severity (~5 hours, 10-12 commits)

### 3.1 Unstructured Task cancellation tracking (MEDIUM)

**Site A — `ContinuousAlignmentService.swift:97-109`:**

The fire-and-forget Task in `processBufferedAudio()` cannot be cancelled by `stop()`.
The timer is invalidated but an in-flight transcription keeps running.

**Fix:**
```swift
private var transcriptionTask: Task<Void, Never>?

private func processBufferedAudio() {
    guard !isProcessing else { return }
    // ...
    isProcessing = true
    transcriptionTask = Task {
        defer { isProcessing = false }
        do {
            try await loadModelIfNeeded()
            let capture = try await transcribe(samples)
            // ...
        } catch {
            logger.error("Transcription failed: \(error.localizedDescription)")
        }
    }
}

func stop() {
    guard isRunning else { return }
    isRunning = false
    transcriptionTask?.cancel()
    transcriptionTask = nil
    timer?.invalidate()
    timer = nil
    audioEngine.removeCaptureTap()
    ringBuffer = nil
    WhisperSession.shared.release()
    whisperKit = nil
    logger.info("Continuous alignment stopped")
}
```

**Site B — `TimelineService.swift:79/101/123`:**

Three `Task { }` blocks in `loadEarlier()`, `loadLater()`, `loadCurrentWindow()`.
These don't have a natural "cancel" moment (they're one-shot loads), but they can
stack on rapid calls. Add a generation counter:

```swift
private var loadGeneration = 0

func loadEarlier() {
    guard !isLoadingEarlier else { return }
    isLoadingEarlier = true
    loadGeneration += 1
    let gen = loadGeneration
    Task {
        defer { isLoadingEarlier = false }
        // ... work ...
        guard gen == loadGeneration else { return }  // newer load superseded us
        await MainActor.run { /* apply results */ }
    }
}
```

**Site C — `ReaderTab.swift:27`:**

`autoAlignmentTask` is a `@State var` (see §8.2). The cancel button at line 293
calls `autoAlignmentTask?.cancel()`, but view teardown doesn't. Fix: cancel in
`.onDisappear`:
```swift
.onDisappear {
    autoAlignmentTask?.cancel()
}
```

**Commit:** `fix: add cancellation tracking to fire-and-forget Tasks in alignment and timeline services`

---

### 3.2 TimelineService queue hop → GRDB async (MEDIUM)

**File:** `EchoCore/Services/TimelineService.swift:36, 172-184`

**Before:**
```swift
private let pushForwardQueue = DispatchQueue(label: "com.echo.audiobooks.timeline.pushforward")

private func pushForwardUncompletedItems() {
    guard let db else { return }
    let now = Date()
    pushForwardQueue.async { [weak self] in
        guard let self else { return }
        do {
            let dao = RealTimeEventDAO(db: db.writer)
            try dao.pushForwardUncompleted(before: now, to: now)
        } catch {
            self.logger.error("Push-forward failed: \(error.localizedDescription)")
        }
    }
}
```

**After:**
```swift
// Delete pushForwardQueue entirely

private func pushForwardUncompletedItems() {
    guard let db else { return }
    let now = Date()
    Task { [weak self] in
        guard let self else { return }
        do {
            try await db.writer.write { db in
                let dao = RealTimeEventDAO(db: db)
                try dao.pushForwardUncompleted(before: now, to: now)
            }
        } catch {
            self.logger.error("Push-forward failed: \(error.localizedDescription)")
        }
    }
}
```

This eliminates the `@MainActor`-isolated `self` capture in a plain queue closure —
the exact pattern Swift 6 strict mode rejects. Also fixes the queue label that
still says `com.echo.audiobooks`.

**Commit:** `refactor: replace TimelineService manual queue with GRDB async write`

---

### 3.3 Unify SWIFT_DEFAULT_ACTOR_ISOLATION across targets (MEDIUM)

**Current state:**
| Target | Setting |
|--------|---------|
| Echo (iOS) | `MainActor` (line 998, 1040) |
| Echo Watch App | `MainActor` (line 1178, 1217) |
| Echo Widget | UNSET (line 779-831) |
| Echo macOS | UNSET (line 695-762) |
| All test targets | UNSET |

**Risk:** Files in `Shared/` compile with different implicit isolation per target.
A class without explicit `@MainActor` annotation is MainActor-isolated in the iOS app
but nonisolated in the widget — hiding potential data races.

**Action:**
1. Set `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` on widget, macOS, and test targets
2. Fix any resulting compilation errors (classes that shouldn't be MainActor will need explicit `nonisolated`)

**Files in Shared/ that may be affected:** Any with class/actor declarations
without explicit isolation. Key suspects:
- `Shared/AppGroupDefaults.swift` — already `@MainActor`
- `Shared/Database/DatabaseService.swift` — has explicit isolation
- DAO files — GRDB records are value types, likely fine

Test by building all targets after the change.

**Commit:** `build: set SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor on all targets for consistent isolation`

---

### 3.4 Migrate OSAtomic → Synchronization framework (MEDIUM)

**File:** `EchoCore/Services/AudioRingBuffer.swift:59, 68, 83, 89`

**Before:**
```swift
private var head: Int32 = 0
private var tail: Int32 = 0

// Producer:
OSAtomicAdd32Barrier(Int32(count), &head)

// Consumer:
let h = Int(OSAtomicAdd32Barrier(0, &head))
```

**After:**
```swift
import Synchronization

private let head = Atomic<Int32>(0)
private var tail: Int32 = 0  // consumer-only, no atomic needed

// Producer (line 59):
head.add(Int32(count), ordering: .releasing)

// Consumer (line 68):
let h = Int(head.load(ordering: .acquiring))

// Consumer peek (line 83):
let h = Int(head.load(ordering: .acquiring))

// Consumer reset (line 89):
tail = Int32(head.load(ordering: .acquiring))
```

**Notes:**
- `Synchronization` is available from iOS 18 / macOS 15 deployment targets (the project targets 26.x, so it's available)
- `.releasing`/`.acquiring` map 1:1 onto the existing OSAtomic barriers
- `head` changes from a stored property (`var head: Int32`) to `Atomic<Int32>` — this is safe because `Atomic` guarantees pointer stability internally
- The old code's `&head` pointer-stability assumption becomes compiler-guaranteed

**Commit:** `refactor: migrate AudioRingBuffer from deprecated OSAtomic to Synchronization Atomic`

---

### 3.5 Async seek API for AudioEngine (MEDIUM)

**File:** `EchoCore/Services/AudioEngine.swift:150-183`

**Before:** Completion-handler-based `seek(to:completion:)` with 12 call sites in
`PlaybackController.swift` each wrapping in `DispatchQueue.main.async`.

**After — add async overload:**
```swift
func seek(to targetSeconds: Double) async -> Bool {
    guard let playerNode, let audioFile, engine != nil else { return false }

    let sampleRate = audioFile.processingFormat.sampleRate
    let totalFrames = audioFile.length
    let clampedTime = max(0, min(targetSeconds, Double(totalFrames) / sampleRate))
    let startFrame = AVAudioFramePosition(clampedTime * sampleRate)
    let framesToPlay = AVAudioFrameCount(totalFrames - startFrame)

    guard framesToPlay > 0 else { return false }

    let wasPlaying = isPlaying
    isPlaying = false
    stopTimeTimer()
    seekGeneration += 1
    playerNode.stop()
    seekOffset = clampedTime
    currentTime = clampedTime

    scheduleSegment(file: audioFile, from: startFrame, frames: framesToPlay)

    if wasPlaying {
        startEngineIfNeeded()
        playerNode.play()
        isPlaying = true
        startTimeTimer()
    }
    return true
}
```

Then update each of the 12 call sites from:
```swift
audioEngine.seek(to: time) { _ in
    DispatchQueue.main.async {
        self.isManualSeeking = false
    }
}
```
To:
```swift
Task {
    _ = await audioEngine.seek(to: time)
    isManualSeeking = false
}
```

Since `PlaybackController` is `@MainActor`, the `Task` inherits the actor and
`isManualSeeking = false` runs on the main actor automatically — no explicit hop needed.

**Also consider:** Making `play()` and `pause()` async if they have similar patterns.
Currently they're synchronous and don't need it, but consistency may be valuable.

**Commit:** `refactor: add async seek API to AudioEngine, removing 12 manual main-queue hops`

---

### 3.6 Security-scoped bookmark creation options (MEDIUM)

**File:** `EchoCore/Services/Persistence.swift:172-178`

**Before:**
```swift
let bookmarkData = try url.bookmarkData(
    options: [.minimalBookmark],
    includingResourceValuesForKeys: nil,
    relativeTo: nil
)
```

**After:**
```swift
let bookmarkData = try url.bookmarkData(
    options: [],  // Empty = full security-scoped bookmark; survives relaunch
    includingResourceValuesForKeys: nil,
    relativeTo: nil
)
```

**Verification:** Test on device: pick folder → force-quit → relaunch → confirm
`startAccessingSecurityScopedResource()` returns `true`. Existing bookmarks created
with `.minimalBookmark` will still work until their next save cycle refreshes them.

**Note:** Keychain storage (lines 168-189) and stale-refresh path (lines 191-222) are
correct and unchanged.

**Commit:** `fix: use full security-scoped bookmark options to ensure relaunch survival`

---

### 3.7 App-group UserDefaults read-modify-write (MEDIUM)

**Files:**
- `EchoCore/Services/Persistence.swift:33, 51, 69, 121, 149`
- `Echo Widget/Models/AppIntent.swift:13, 50`

**Problem:** Multi-key dictionaries (`progressKey`, `speedKey`, `loopModeKey`, `lastTrackKey`)
grow unboundedly (one entry per book ever played). Concurrent writes from widget and
phone lose updates (last-writer-wins on the whole dictionary).

**Fix — one key per book (simpler approach):**
```swift
// Instead of:
private let progressKey = "EchoAudiobooks.progress.dictionary"
// Read → mutate one entry → write entire dict

// Use:
private func progressKey(for bookID: String) -> String {
    "EchoAudiobooks.progress.\(bookID)"
}
// Read → write single value; no cross-book collisions
```

Update all 5 save/get pairs in Persistence.swift. The widget only writes to
progress — update its key pattern too.

**Migration:** On first read, check for the old dictionary key. If present, migrate
values to the new per-book keys, then delete the old dictionary.

```swift
func migrateIfNeeded() {
    if let oldDict = defaults.dictionary(forKey: "EchoAudiobooks.progress.dictionary") {
        for (bookID, value) in oldDict {
            defaults.set(value, forKey: progressKey(for: bookID))
        }
        defaults.removeObject(forKey: "EchoAudiobooks.progress.dictionary")
    }
    // Repeat for speed, loopMode, lastTrack dictionaries
}
```

**Commit:** `fix: store per-book defaults keys to prevent unbounded growth and cross-process write conflicts`

---

### 3.8 Watch marquee animation pausing (MEDIUM)

**File:** `Echo Watch App/Views/PlayerPage.swift:919`

**Before:**
```swift
TimelineView(.animation) { timeline in
```

**After:**
```swift
TimelineView(.animation(minimumInterval: 0.5, paused: !isPlaying || isLuminanceReduced)) { timeline in
```

Need to add `@Environment(\.isLuminanceReduced) private var isLuminanceReduced` to
`MarqueeText` (or pass it from the parent `PlayerPage`).

**Additional optimization:** Pause after one full scroll cycle:
```swift
@State private var cycleCount = 0
// In the TimelineView body:
let cycle = Int((time * scrollSpeed) / distance)
if cycle > cycleCount + 1 { /* pause? */ }
```

Simpler approach: just adding `minimumInterval` + `paused` flags handles 90% of the
battery concern. The one-cycle pause is a nice-to-have.

**Commit:** `perf: pause watch marquee animation when not playing or wrist is down`

---

### 3.9 AutoAlignmentProgressView — remove timer, use @Observable directly (MEDIUM)

**File:** `EchoCore/Views/AutoAlignmentProgressView.swift:132-165`

**Problem:** A 0.3s `Timer` copies `AutoAlignmentState` (already `@Observable`) into
local `@State` mirrors. This adds 300ms latency, manual invalidate-on-disappear
bookkeeping, and unnecessary complexity.

**Fix:**
- Delete the timer (`pollTimer`), `startPolling()`, `stopPolling()`, `refresh()`
- Delete all local mirror `@State` properties (phase, progress, statusMessage, etc.)
- Read `sharedState` properties directly in `body`
- Inject `sharedState` and keep as a stored `let` (already the case)
- Delete `.onAppear { startPolling() }` and `.onDisappear { stopPolling() }`

The view body already uses `phase`, `progress`, etc. — just replace with
`sharedState.phase`, `sharedState.progress`, etc.

**Before (conceptual):**
```swift
@State private var phase = AutoAlignmentState.Phase.idle
// ... 7 more @State mirrors ...
@State private var pollTimer: Timer?

var body: some View {
    // uses local phase, progress, etc.
}

private func refresh() {
    phase = sharedState.phase
    // ... copy 8 more properties ...
}
```

**After (conceptual):**
```swift
// No @State mirrors. No Timer. No refresh().

var body: some View {
    // Use sharedState.phase, sharedState.progress, etc. directly
    Text(sharedState.statusMessage)
    ProgressView(value: sharedState.progress)
    // ...
}
```

Since `AutoAlignmentState` is `@Observable`, SwiftUI automatically tracks which
properties are read in `body` and only re-renders when those specific properties change.
This is strictly better than the 0.3s polling.

**Commit:** `perf: remove Timer polling in AutoAlignmentProgressView; read @Observable state directly`

---

### 3.10 Unify SnippetPlayer and AudioSnippetPlayer (MEDIUM)

**Files:**
- `EchoCore/Services/SnippetPlayer.swift` — used by `PlayerModel`
- `EchoCore/Services/AudioSnippetPlayer.swift` — used by `Bookmarks.swift:396, 752`

**Comparison:**

| Feature | SnippetPlayer | AudioSnippetPlayer |
|---------|---------------|-------------------|
| Actor isolation | `@MainActor` | none |
| Play range | startTime–endTime segment | full file |
| Volume control | none | `volume: Float` parameter |
| Generation guard | ✅ `currentGeneration` | ❌ |
| Error handling | Logger on all paths | Logger on all paths |
| Stop/cleanup | `stop()` tears down engine | `stop()` tears down engine |
| Callbacks | `onPlaybackWillStart`/`onPlaybackDidEnd` closures | `completion` closure |

**Plan:** Keep `SnippetPlayer` (better: `@MainActor`, generation guard, segment support)
and add the missing features from `AudioSnippetPlayer`:
1. Add `volume: Float` parameter to `SnippetPlayer.play()`
2. Add a convenience `play(url:volume:completion:)` that plays the whole file
3. Update the two `Bookmarks.swift` call sites (lines 396, 752) to use `SnippetPlayer`
4. Delete `AudioSnippetPlayer.swift`

**Commit:** `refactor: unify snippet players into single @MainActor SnippetPlayer with volume support`

---

### 3.11 Rebrand decision documentation (MEDIUM)

**Decision needed:** Change all `com.orbit.*` identifiers to `com.echo.*` BEFORE first
public release, or freeze them permanently.

**Current orbit-identifiers (complete list):**
- 8 `PRODUCT_BUNDLE_IDENTIFIER` values in project.pbxproj
- `group.com.echo.audiobooks` in `Shared/AppGroupDefaults.swift:6` + entitlements
- `iCloud.com.echo.audiobooks` in entitlements
- `Logger.orbitSubsystem = "com.echo.audiobooks"` in `Shared/Logger+Subsystem.swift:8`
- Queue label `"com.echo.audiobooks.timeline.pushforward"` in `TimelineService.swift:36` (fixed in §3.2)
- `com.echo.pro.unlock` IAP product ID in build settings

**Pre-release change:** Safe to rename all of these. Requires:
- New bundle IDs in Xcode + App Store Connect
- New app group in Capabilities + entitlements
- New iCloud container (or migration from old one)
- New IAP product ID in App Store Connect

**Post-release freeze:** Document in README.md that the `orbit` identifiers are
intentional legacy and won't change. Add to CLAUDE.md.

**This plan recommends:** Change now (pre-release). The only cheap moment.

**Commit:** `refactor: migrate all bundle/group/iCloud identifiers from com.orbit to com.echo domain`

---

## Phase 4: Low Severity (~4 hours, 14-16 commits)

### 4.1 Remove @unchecked Sendable from ReaderCardItem (LOW)

**File:** `EchoCore/Models/ReaderCardItem.swift:54`

**Before:**
```swift
extension ReaderCardItem: @unchecked Sendable {}
```

**After:**
```swift
extension ReaderCardItem: Sendable {}
```

`EPubBlockRecord` already declares `Sendable` (value type). If the compiler rejects
plain `Sendable`, the error identifies the actual non-Sendable member to fix —
that's strictly better than silently masking it.

**Commit:** `refactor: replace @unchecked Sendable with plain Sendable on ReaderCardItem`

---

### 4.2 View-layer Timer.scheduledTimer → .task(id:) (LOW)

**Sites to convert:**

**A — `Echo Watch App/Views/PlayerPage.swift:816`** (quick-bookmark countdown):
```swift
// Before: Timer polling every 0.2s
quickBookmarkTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in ... }

// After: .task(id:) with Task.sleep loop
.task(id: quickBookmarkStartedAt) {
    guard let startedAt = quickBookmarkStartedAt else { return }
    while !Task.isCancelled {
        let elapsed = Date().timeIntervalSince(startedAt)
        let remaining = max(0, quickBookmarkTimeout - elapsed)
        quickBookmarkRemaining = remaining
        if remaining <= 0 {
            completeQuickBookmarkFromTimeout()
            break
        }
        try? await Task.sleep(for: .milliseconds(200))
    }
}
```

**B — `Echo Watch App/Views/ContentView.swift:216`** (crown scrub idle timer):
```swift
// Before: one-shot Timer for 1s
scrubIdleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in ... }

// After:
.task(id: accumulatedScrubDelta) {
    try? await Task.sleep(for: .seconds(1))
    if !Task.isCancelled {
        isScrubbingActive = false
        accumulatedScrubDelta = 0.0
    }
}
```

**C — `EchoCore/Views/ManualAlignmentSheet.swift:95, 103`:** Read these sites and
apply the same pattern. These are likely scrubber-related timers that can be
replaced with `.task(id:)` loops.

**Commit:** `refactor: replace view-layer Timer.scheduledTimer with .task(id:) async loops`

---

### 4.3 Artwork palette cache poison fix (LOW)

**File:** `EchoCore/ViewModels/PlayerModel.swift:206-219`

**Before:**
```swift
var artworkPalette: DominantColorExtractor.ArtworkPalette {
    let version = currentDisplayArtworkVersion
    if version != cachedPaletteVersion || cachedPalette == nil {
        if let image = currentDisplayArtwork ?? thumbnailImage {
            cachedPalette = DominantColorExtractor.extractPalette(from: image)
        } else {
            cachedPalette = DominantColorExtractor.ArtworkPalette(
                rawAccent: nil, candidates: [], background: []
            )
        }
        cachedPaletteVersion = version  // ← CACHES EVEN THE EMPTY PALETTE
    }
    return cachedPalette!
}
```

**After:**
```swift
var artworkPalette: DominantColorExtractor.ArtworkPalette {
    let version = currentDisplayArtworkVersion
    if version != cachedPaletteVersion || cachedPalette == nil {
        if let image = currentDisplayArtwork ?? thumbnailImage,
           let palette = DominantColorExtractor.extractPalette(from: image),
           palette.rawAccent != nil {
            cachedPalette = palette
            cachedPaletteVersion = version  // ← Only cache successful extractions
        } else {
            // Return empty palette WITHOUT caching the version,
            // so next access will retry extraction
            return DominantColorExtractor.ArtworkPalette(
                rawAccent: nil, candidates: [], background: []
            )
        }
    }
    return cachedPalette!
}
```

Wait — need to check if `extractPalette` can return nil. Looking at the current code,
it always returns a non-optional `ArtworkPalette`. The issue is when `image` is nil:
an empty palette is cached under the current version. 

Better fix: only update `cachedPaletteVersion` when we actually got an image:
```swift
if let image = currentDisplayArtwork ?? thumbnailImage {
    cachedPalette = DominantColorExtractor.extractPalette(from: image)
    cachedPaletteVersion = version
} else {
    return DominantColorExtractor.ArtworkPalette(
        rawAccent: nil, candidates: [], background: []
    )
}
```

**Commit:** `fix: don't cache empty artwork palette — retry extraction on next access`

---

### 4.4 Clamp speed in time-remaining labels (LOW)

**File:** `EchoCore/Services/PlaybackProgressPresenter.swift:88, 100-101`

**Before:**
```swift
let speed = speedProvider?() ?? 1.0
let remaining = (duration - elapsed) / speed
```

**After:**
```swift
let speed = max(0.1, speedProvider?() ?? 1.0)  // clamp to avoid Inf/NaN
let remaining = (duration - elapsed) / speed
```

**Commit:** `fix: clamp playback speed to minimum 0.1 to prevent Inf in time-remaining labels`

---

### 4.5 CarPlay force-unwrap → if-let binding (LOW)

**File:** `EchoCore/CarPlay/CarPlaySceneDelegate.swift:44-45`

**Before:**
```swift
if model?.isMultiM4B == true, !model!.aggregatedChapters.isEmpty {
```

**After:**
```swift
if let model, model.isMultiM4B, !model.aggregatedChapters.isEmpty {
```

**Commit:** `refactor: replace force-unwrap with if-let binding in CarPlay chapter list`

---

### 4.6 Balance stopAccessingSecurityScopedResource (LOW)

**File:** `EchoCore/Services/EPUBAutoImportScanner.swift:38-45`

**Before:**
```swift
let needsParentScope = !folderIsDirectory
if needsParentScope {
    _ = targetURL.startAccessingSecurityScopedResource()  // ← result DISCARDED
}
defer {
    if needsParentScope {
        targetURL.stopAccessingSecurityScopedResource()  // ← unconditionally stops
    }
}
```

**After:**
```swift
let needsParentScope = !folderIsDirectory
let didStartParentScope = needsParentScope && targetURL.startAccessingSecurityScopedResource()
defer {
    if didStartParentScope {
        targetURL.stopAccessingSecurityScopedResource()
    }
}
```

This matches the correct pattern at `Persistence.swift:273-274`.

**Commit:** `fix: balance stopAccessingSecurityScopedResource calls in EPUB auto-import scanner`

---

### 4.7 Application context complete-key-set guard rail (LOW)

**File:** `EchoCore/Services/WatchSyncManager.swift`

The `stateProvider` closure builds the application context dictionary. Add a DEBUG
assertion that all expected keys are present:

```swift
#if DEBUG
private let expectedContextKeys: Set<String> = [
    "bookTitle", "chapterTitle", "progress", "duration",
    "speed", "isPlaying", "loopMode", "sleepTimerRemaining",
    "hasEPUB", "currentArtworkVersion", "bookmarkCount"
    // ... complete with actual keys from WatchStateContextBuilder
]

func syncToWatch(reason: SyncReason = .significant) {
    // ...
    if reason == .significant {
        #if DEBUG
        if let context {
            let missing = expectedContextKeys.subtracting(context.keys)
            assert(missing.isEmpty, "Watch application context missing keys: \(missing)")
        }
        #endif
        try session.updateApplicationContext(context)
    }
}
```

Also funnels all context sends through a single builder method in
`WatchStateContextBuilder` so keys can't be omitted by accident.

**Commit:** `fix: add DEBUG assertion for complete watch application context key set`

---

### 4.8 XML parser explicit entity resolution hardening (LOW)

**File:** `Shared/EPUBXMLParsing.swift:50, 82, 134, 218`

At each `XMLParser` construction site, add:
```swift
parser.shouldResolveExternalEntities = false  // Trust boundary: parsing untrusted EPUB input
```

This is already the default, but explicit is safer and documents the trust boundary.

**Commit:** `security: explicitly set shouldResolveExternalEntities=false on EPUB XML parsers`

---

### 4.9 Split shared entitlements file (LOW)

**Current:** `Echo.entitlements` at repo root is shared by watch app AND watch widget.
The widget inherits the iCloud container it doesn't need.

**Action:**
1. Create `Echo Watch App/EchoWatchApp.entitlements` with only the app group
2. Create `Echo Widget/EchoWidget.entitlements` with only the app group
3. Update pbxproj CODE_SIGN_ENTITLEMENTS paths for both targets
4. Keep the root `Echo.entitlements` for the iOS target

**Commit:** `refactor: split shared entitlements into per-target files with least privilege`

---

### 4.10 Cache watch artwork JPEG encode (LOW)

**File:** `EchoCore/Services/ArtworkCache.swift:129`

Add an in-memory cache keyed by artwork version:
```swift
private var cachedWatchJPEG: (version: Int, data: Data)?

func watchJPEGData(version: Int) -> Data? {
    if let cached = cachedWatchJPEG, cached.version == version {
        return cached.data
    }
    guard let image = watchImage else { return nil }
    let data = image.jpegData(compressionQuality: 0.75)
    if let data {
        cachedWatchJPEG = (version, data)
    }
    return data
}
```

**Commit:** `perf: cache watch artwork JPEG encode keyed by artwork version`

---

### 4.11 Move alignment-workflow @State to view model (LOW)

**File:** `EchoCore/Views/ReaderTab.swift:11-29` + `EchoCore/Views/ReaderTab+Alignment.swift:8`

The extension accesses these internal `@State` properties:
- `autoAlignmentTask` — already used for cancel
- `showAutoAlignmentProgress`, `showAutoAlignmentFailedAlert`, `autoAlignmentErrorMessage`
- `autoAlignmentState`

**Fix:** Move these alignment-workflow properties into `ReaderFeedViewModel` (or into
`AutoAlignmentState` itself if it can own the task handle). Then mark remaining
`@State` as `private`.

The `ReaderTab+Alignment.swift` extension methods already have access to `viewModel`
and can route through it.

**Commit:** `refactor: move alignment workflow @State from ReaderTab to ReaderFeedViewModel`

---

### 4.12 Extract magic constants (LOW)

**JPEG/artwork constants** — Add to `Shared/` or `EchoCore/Utilities/`:
```swift
enum ImageEncoding {
    static let bookmarkMaxDimension: CGFloat = 1600
    static let bookmarkJPEGQuality: CGFloat = 0.84
    static let watchTransferJPEGQuality: CGFloat = 0.75
}
```

Update:
- `EchoCore/Views/Bookmarks.swift:694` → `ImageEncoding.bookmarkMaxDimension`, `ImageEncoding.bookmarkJPEGQuality`
- `EchoCore/Services/ArtworkCache.swift:129` → `ImageEncoding.watchTransferJPEGQuality`

**Watch messaging command key** — Add to `Shared/` or wherever watch message types are defined:
```swift
enum WatchMessageKey {
    static let command = "command"
    static let params = "params"
    // ... add others as discovered
}
```

Update all 6 string-literal `"command"` sites across `Echo Watch App/` and `EchoCore/`.

**Commit:** `refactor: extract magic JPEG constants and watch messaging keys to named enums`

---

### 4.13 Accessibility sweep (LOW)

Run a targeted search for unlabeled icon-only buttons:
```bash
grep -rn "Image(systemName:" EchoCore/Views/ Echo\ Watch\ App/Views/ --include="*.swift" | grep -v "accessibilityLabel"
```

Focus on these files cited by the audit:
- `Bookmarks.swift`
- `PlaylistView.swift`
- ReaderTab toolbars

For each icon-only button without a label, add:
```swift
.accessibilityLabel("Descriptive action name")
```

Run Accessibility Inspector audit once to verify.

**Commit:** `a11y: add accessibility labels to remaining unlabeled icon-only buttons`

---

### 4.14 TODO census (informational)

**File:** `EchoCore/CarPlay/CarPlaySceneDelegate.swift` — exactly one TODO

Read it. If actionable now, do it. Otherwise document in ROADMAP.md.

**Commit:** (only if action taken) `chore: address sole remaining TODO in CarPlaySceneDelegate`

---

## Cross-Cutting Recommendations (from §10)

These are architectural, not single-commit items. They should become ROADMAP.md entries:

1. **Swift 6 migration project** — After §3.3 (unified isolation), flip one target at a time
   to Swift 6 language mode. The codebase is unusually close (zero warnings, Approachable
   Concurrency on, no `nonisolated(unsafe)` abuse).

2. **Async-database policy** — After §2.2, encode the rule: hot-path reads/writes are async;
   import-time batch work may stay sync. Add async DAO variants.

3. **Task lifecycle convention** — After §3.1, the store-replace-cancel pattern should be
   consistent everywhere. Consider a tiny utility:
   ```swift
   @MainActor
   final class TrackedTask<T> {
       private var task: Task<T, Error>?
       func run(_ operation: @escaping () async throws -> T) { ... }
       func cancel() { ... }
   }
   ```

4. **Close the rebrand** — §3.11, §1.1, §1.6: retire "Orbit" from the repo entirely
   (identifiers, docs, dead directories, typo).

5. **Decide macOS target status** — §2.1: revive through `Shared/` or park explicitly.
   Document the decision in README.md and ARCHITECTURE.md.

---

## Commit Order (optimal)

```
Phase 1 (independent, any order):
  1. chore: remove empty Orbit-branded directory stubs
  2. chore: untrack scratch/ directory, add build.log and __pycache__ to .gitignore
  3. fix: correct "Audiobookk" typo in macOS bundle display name
  4. fix: replace print() with Logger and add @MainActor hop in app-icon completion
  5. refactor: extract "TranscriptDidUpdate" notification name to constant
  6. refactor: move LoopMode and SleepTimerMode enums to Models/
  7. docs: update CLAUDE.md Tools description to reflect current state

Phase 2:
  8. fix: revive macOS target — link WhisperKit, remove orphaned shell phase, add app-group entitlement
  9. chore: remove AudiobookPlayerUIArchitect design scaffold and companion Ruby script
 10. perf: convert hot-path GRDB reads to async to avoid main-thread blocking

Phase 3:
 11. fix: add cancellation tracking to fire-and-forget Tasks
 12. refactor: replace TimelineService manual queue with GRDB async write
 13. build: set SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor on all targets
 14. refactor: migrate AudioRingBuffer from deprecated OSAtomic to Synchronization Atomic
 15. refactor: add async seek API to AudioEngine
 16. fix: use full security-scoped bookmark options
 17. fix: store per-book defaults keys to prevent write conflicts
 18. perf: pause watch marquee animation when not playing or wrist down
 19. perf: remove Timer polling in AutoAlignmentProgressView
 20. refactor: unify snippet players into single @MainActor SnippetPlayer
 21. refactor: migrate all bundle/group/iCloud identifiers to com.echo domain (decision-dependent)

Phase 4:
 22. refactor: replace @unchecked Sendable with plain Sendable on ReaderCardItem
 23. refactor: replace view-layer Timer.scheduledTimer with .task(id:) async loops
 24. fix: don't cache empty artwork palette
 25. fix: clamp playback speed to prevent Inf in time-remaining labels
 26. refactor: replace force-unwrap with if-let binding in CarPlay chapter list
 27. fix: balance stopAccessingSecurityScopedResource calls in EPUB scanner
 28. fix: add DEBUG assertion for complete watch application context key set
 29. security: explicitly set shouldResolveExternalEntities=false on EPUB XML parsers
 30. refactor: split shared entitlements into per-target files
 31. perf: cache watch artwork JPEG encode keyed by artwork version
 32. refactor: move alignment workflow @State from ReaderTab to ReaderFeedViewModel
 33. refactor: extract magic JPEG constants and watch messaging keys to named enums
 34. a11y: add accessibility labels to remaining unlabeled icon-only buttons
```

---

## Estimated Totals

| Phase | Items | Estimated Time |
|-------|-------|----------------|
| Phase 1: Quick Wins | 8 commits | ~2 hours |
| Phase 2: Critical + High | 3 commits | ~3-4 hours |
| Phase 3: Medium | 10-12 commits | ~5 hours |
| Phase 4: Low | 14-16 commits | ~4 hours |
| **Total** | **~35-39 commits** | **~14-15 hours** |

Realistic overnight throughput: Phases 1-3 (the high-impact items) in ~8-10 hours.
Phase 4 can be deferred to the next session if needed.

---

## Verification at Each Phase

After each phase, run:
```bash
xcodebuild -project Echo.xcodeproj -scheme Echo build 2>&1 | tail -20
```

After Phase 2.1, also verify:
```bash
xcodebuild -project Echo.xcodeproj -scheme "Echo macOS" build 2>&1 | tail -5
```

Goal: zero warnings maintained (currently clean), all targets build.
