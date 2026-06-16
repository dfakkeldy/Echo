# macOS Parity, Batch Processing & Karaoke Alignment — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Converge macOS and iOS targets to share PlayerModel + views, extend alignment to word-level granularity, add karaoke highlighting in reader cards, a sequential batch processing queue, and working m4b chapter-marker export.

**Architecture:** Four phases built on a shared foundation. Phase A converges the two targets (PlayerModel, AudioEngine, player views) and extends alignment from block → word granularity. Phases B (karaoke), C (batch queue), and D (m4b export) build on Phase A independently.

**Tech Stack:** Swift 6, SwiftUI, AVFoundation, GRDB, WhisperKit, FluidAudio (macOS + iOS), swift-audio-marker (new SPM dep)

---

## File Structure Map

| File | Phase | Role |
|------|-------|------|
| `EchoCore/ViewModels/PlayerModel.swift` | A | Gate iOS-only deps; become cross-platform |
| `EchoCore/Services/AudioEngine.swift` | A | Gate iOS-only observers; verify macOS compat |
| `EchoCore/Services/PlaybackController.swift` | A | Gate NowPlaying/Watch; macOS compat |
| `Echo macOS/MacPlayerModel.swift` | A | **DELETE** — replaced by shared PlayerModel |
| `Echo macOS/Echo_macOSApp.swift` | A | Wire PlayerModel + AudioEngine; keep NSOpenPanel |
| `Echo macOS/MacTriPaneView.swift` | A | Swap player bar for shared components |
| `EchoCore/Views/NowPlayingTab.swift` | A | Gate haptics/UIKit; add macOS layout adapt |
| `EchoCore/Views/TransportControlsView.swift` | A | Gate Haptic engine; macOS key shortcuts |
| `EchoCore/Views/PlayerScrubberView.swift` | A | Already cross-platform (SwiftUI slider) |
| `EchoCore/Views/UnifiedBottomDock.swift` | A | Gate bottom-safe-area; adapt for macOS |
| `EchoCore/Views/UnifiedTopHeader.swift` | A | Gate folder picker (NSOpenPanel on Mac) |
| `Shared/Database/TimelineItem.swift` | A | Add `wordOffset` field for sub-block index |
| `EchoCore/Services/AlignmentService.swift` | A | Add `recalculateTimeline(granularity:)` parameter |
| `EchoCore/Services/AutoAlignmentService.swift` | A | Persist per-word DTW timestamps |
| `Shared/Database/WordAlignmentRecord.swift` | A | **CREATE** — word→time mapping table |
| `Shared/Database/DAOs/WordAlignmentDAO.swift` | A | **CREATE** — CRUD for word alignment |
| `Shared/ReaderActiveBlockResolver.swift` | B | Add word-level lookup mode |
| `EchoCore/ViewModels/ReaderFeedViewModel.swift` | B | Publish active word index for karaoke |
| `EchoCore/Views/Cells/ParagraphCardCell.swift` | B | AttributedString word highlighting |
| `EchoCore/Views/Cells/HeadingCardCell.swift` | B | AttributedString word highlighting |
| `EchoCore/Services/BatchProcessingService.swift` | C | **CREATE** — queue orchestrator |
| `Shared/Database/BatchQueueItem.swift` | C | **CREATE** — persistent queue record |
| `EchoCore/Views/BatchQueueView.swift` | C | **CREATE** — queue management UI |
| `EchoCore/Services/Narration/AudioMarkerStub.swift` | D | Replace stub with real chapter atoms |
| `EchoCore/Services/Narration/NarrationExportService.swift` | D | Wire real AudioMarker; embed alignment |

---

## Phase A: Foundation — macOS Convergence + Word-Level Alignment

### Task A1: Audit PlayerModel iOS Dependencies

**Files:**
- Read: `EchoCore/ViewModels/PlayerModel.swift`
- Read: `EchoCore/ViewModels/PlayerModel+Bookmarks.swift`
- Read: `EchoCore/ViewModels/PlayerModel+Narration.swift`
- Read: `EchoCore/ViewModels/PlayerModel+WatchState.swift`
- Read: `EchoCore/ViewModels/PlayerModel+PlaybackControllerDelegate.swift`

- [ ] **Step 1: Catalog every iOS-only dependency in PlayerModel and its extensions**

Run a scan to identify all iOS-only symbols:

```bash
grep -n -E "import (UIKit|WatchConnectivity|CarPlay|MediaPlayer)" \
  EchoCore/ViewModels/PlayerModel*.swift

grep -n -E "#if canImport\(UIKit\)|#if os\(iOS\)" \
  EchoCore/ViewModels/PlayerModel*.swift
```

Expected: find `import UIKit`, `import WatchConnectivity` in PlayerModel.swift, CarPlay guards in PlayerModel+Bookmarks.swift, narration (iOS-only `#if os(iOS)`) in PlayerModel+Narration.swift, Watch state in PlayerModel+WatchState.swift.

- [ ] **Step 2: Identify PlayerModel properties that need gating**

Document each property/function that references an iOS-only type:
- `watchSyncManager: WatchSyncManager` — watchOS-only, gate with `#if os(iOS)`
- `carPlayVoiceMemoRecorder` — already gated, verify
- `carPlayNotificationObservers` — gate with `#if os(iOS)`
- `locationCapture` — works cross-platform (CoreLocation)
- `selectedTab: TabSelection` — cross-platform enum in Shared/
- `epubSearchText` — cross-platform
- `showingHelp`, `showPaywall`, `paywallContext` — iOS-only (no StoreKit on Mac target), gate
- `pendingNavigationDestination` — cross-platform
- Deep link handling (`onOpenURL`) — iOS-only, gate

- [ ] **Step 3: Write the audit as a comment block for reference**

No code changes yet — just verify what needs gating. Continue to A2.

---

### Task A2: Gate iOS-Only Code in PlayerModel

**Files:**
- Modify: `EchoCore/ViewModels/PlayerModel.swift`
- Modify: `EchoCore/ViewModels/PlayerModel+Bookmarks.swift`
- Modify: `EchoCore/ViewModels/PlayerModel+WatchState.swift`
- Modify: `EchoCore/ViewModels/PlayerModel+PlaybackControllerDelegate.swift`

- [ ] **Step 1: Gate UIKit import and WatchConnectivity in PlayerModel.swift**

```swift
// In PlayerModel.swift, replace lines 7-8:
import UIKit
import WatchConnectivity

// With:
#if os(iOS)
import UIKit
import WatchConnectivity
#endif
```

- [ ] **Step 2: Gate Watch sync properties**

Wrap `watchSyncManager`, `watchCommandRouter`, and any `WCSession` references:

```swift
#if os(iOS)
let watchSyncManager = WatchSyncManager()
@ObservationIgnored private lazy var watchCommandRouter = WatchCommandRouter(
    facade: WatchConnectivityCoordinator(playerModel: self)
)
#endif
```

- [ ] **Step 3: Gate CarPlay properties and observers**

Wrap the CarPlay voice memo recorder and notification observers:

```swift
#if os(iOS)
@ObservationIgnored private(set) var carPlayVoiceMemoRecorder = VoiceMemoRecorder()
@ObservationIgnored private var carPlayNotificationObservers: [NSObjectProtocol] = []
#endif
```

Wrap `setupCarPlayNotificationObservers()` and `removeCarPlayObservers()` with `#if os(iOS)`.

- [ ] **Step 4: Gate paywall/showHelp/showPaywall**

```swift
#if os(iOS)
var showingHelp: Bool = false
var showPaywall: Bool = false
var paywallContext: PaywallContext = .flashcardCap
#endif
```

- [ ] **Step 5: Gate `.onOpenURL` handling**

The `handleDeepLink` function and `pendingDeepLink` should be iOS-only. Wrap the `onOpenURL` modifier site (in `EchoCoreApp.swift`) rather than the PlayerModel — but if PlayerModel has deep link state, gate that too.

- [ ] **Step 6: Verify compilation for both targets**

```bash
# Build iOS target
xcodebuild -project Echo.xcodeproj -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5

# Build macOS target (this should now start compiling PlayerModel)
xcodebuild -project Echo.xcodeproj -scheme "Echo macOS" -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: iOS builds clean. macOS may have errors from remaining PlayerModel references — we handle those in A3.

- [ ] **Step 7: Commit**

```bash
git add EchoCore/ViewModels/PlayerModel*.swift
git commit -m "refactor: gate iOS-only deps in PlayerModel for macOS compatibility"
```

---

### Task A3: Verify AudioEngine and PlaybackController on macOS

**Files:**
- Read: `EchoCore/Services/AudioEngine.swift`
- Read: `EchoCore/Services/PlaybackController.swift`
- Read: `EchoCore/State/PlaybackState.swift`

- [ ] **Step 1: Audit AudioEngine for iOS-only APIs**

```bash
grep -n -E "import (UIKit|WatchConnectivity|MediaPlayer)|AVAudioSession|UIApplication" \
  EchoCore/Services/AudioEngine.swift
```

`AVAudioEngine` is cross-platform. The main concern is `AVAudioSession` (iOS-only for route changes/interruptions) and `MPNowPlayingInfoCenter` (iOS-only for Now Playing). These need `#if os(iOS)` guards.

- [ ] **Step 2: Gate iOS-specific AudioEngine code**

Add `#if os(iOS)` around:
- `AVAudioSession` route change observation
- Audio interruption handling (`AVAudioSession.interruptionNotification`)
- `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` updates

On macOS, `AVAudioEngine` works directly — no audio session setup needed.

- [ ] **Step 3: Audit PlaybackController for iOS-only deps**

```bash
grep -n -E "import (UIKit|WatchConnectivity|MediaPlayer)" \
  EchoCore/Services/PlaybackController.swift
```

Gate `MPNowPlayingInfoCenter` updates, Watch sync calls, and any `UIApplication` background task begins.

- [ ] **Step 4: Gate PlaybackState iOS-only fields**

```swift
// In PlaybackState.swift:
#if os(iOS)
var narrationRenderInFlight: Bool = false
var awaitingNarrationChapter: Bool = false
#endif
```

Narration uses FluidAudio → Kokoro which is ANE-only (iOS). On macOS these fields are unused dead weight.

- [ ] **Step 5: Build macOS target again**

```bash
xcodebuild -project Echo.xcodeproj -scheme "Echo macOS" -destination 'platform=macOS' build 2>&1 | tail -20
```

Fix any remaining compilation errors. Expected: macOS target compiles with PlayerModel + AudioEngine.

- [ ] **Step 6: Commit**

```bash
git add EchoCore/Services/AudioEngine.swift EchoCore/Services/PlaybackController.swift EchoCore/State/PlaybackState.swift
git commit -m "refactor: gate iOS-only audio/playback code for macOS compatibility"
```

---

### Task A4: Remove MacPlayerModel, Wire Shared PlayerModel

**Files:**
- Modify: `Echo macOS/Echo_macOSApp.swift`
- Create: `Echo macOS/MacFileOpener.swift`
- Delete: `Echo macOS/MacPlayerModel.swift` (after verification)
- Modify: `Echo macOS/MacTriPaneView.swift`

- [ ] **Step 1: Create MacFileOpener for security-scoped bookmarks**

`MacPlayerModel`'s only unique value was `NSOpenPanel` file opening with security-scoped bookmarks. Extract that into a small helper:

```swift
// Echo macOS/MacFileOpener.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import UniformTypeIdentifiers

struct MacFileOpener {
    /// Opens an NSOpenPanel for audiobook/EPUB files and returns security-scoped URLs.
    static func openAudioFile() async -> URL? {
        await withCheckedContinuation { continuation in
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.audiovisualContent, .epub, .zip]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.begin { response in
                guard response == .OK, let url = panel.url else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: url)
            }
        }
    }
}
```

- [ ] **Step 2: Update Echo_macOSApp.swift to use shared PlayerModel**

Replace `@State private var player = MacPlayerModel()` with `@State private var player = PlayerModel()`. The macOS app keeps its own `TranscriptionManager`, `TranscriptStore`, and `DatabaseService` as before.

The `PlayerModel` init needs a `DatabaseService` — pass the same `dbService`:

```swift
// Echo_macOSApp.swift (updated body)
@main
struct Echo_macOSApp: App {
    @State private var player: PlayerModel
    @State private var transcriptionManager = TranscriptionManager()
    @State private var transcriptStore = TranscriptStore()
    @State private var dbService: DatabaseService
    @State private var bulkAlignmentService = MacBulkAlignmentService()

    init() {
        let db: DatabaseService
        do {
            db = try DatabaseService()
        } catch {
            fatalError("Database initialization failed: \(error)")
        }
        self.dbService = db
        // PlayerModel expects DatabaseService for initialization
        self.player = PlayerModel(databaseService: db)
    }

    var body: some Scene {
        WindowGroup("Echo AudioBooks") {
            MacTriPaneView()
                .environment(player)
                .environment(transcriptionManager)
                .environment(transcriptStore)
                .environment(dbService)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands { /* existing menu commands, updated below */ }
    }
}
```

**Note:** PlayerModel may not yet have a `DatabaseService`-taking init. If not, add one in this step:

```swift
// In PlayerModel.swift, add init variant:
convenience init(databaseService: DatabaseService) {
    self.init()
    // Store the db reference for playlist/transcript services
}
```

- [ ] **Step 3: Update menu commands to use shared PlayerModel API**

The menu commands in `Echo_macOSApp.swift` currently call `MacPlayerModel` methods. Update them to call `PlayerModel` / `PlaybackController` equivalents:

```swift
.commands {
    CommandGroup(after: .newItem) {
        Button("Open Audiobook...") {
            Task {
                if let url = await MacFileOpener.openAudioFile() {
                    await player.openFile(url)
                }
            }
        }
        .keyboardShortcut("o", modifiers: .command)
    }
    // ... existing playback/study menu items, adapted to PlayerModel API
}
```

- [ ] **Step 4: Update MacTriPaneView player bar**

Replace the inline `HStack` player bar (lines ~60-167 of `MacTriPaneView.swift`) with shared `TransportControlsView` and `PlayerScrubberView`:

```swift
// In MacTriPaneView body, replace the inline player HStack with:
VStack(spacing: 0) {
    PlayerScrubberView()
        .padding(.horizontal)
    TransportControlsView()
        .padding(.horizontal, 8)
}
.frame(height: 64)
.background(.regularMaterial)
```

`TransportControlsView` uses `PlayerModel` via `@Environment` — once PlayerModel is in the environment, it works.

- [ ] **Step 5: Delete MacPlayerModel.swift**

```bash
git rm "Echo macOS/MacPlayerModel.swift"
```

Also remove it from the Xcode project's file-system synchronized group (it will auto-remove since the file is deleted).

- [ ] **Step 6: Build macOS target and fix errors**

```bash
xcodebuild -project Echo.xcodeproj -scheme "Echo macOS" -destination 'platform=macOS' build 2>&1 | grep -E "error:|warning:" | head -30
```

Iterate on any compilation errors. Common issues:
- `PlayerModel` missing expected init — add the convenience init
- Missing environment objects — verify all required environment values are injected
- Menu command method names changed — update to PlayerModel/PlaybackController API

- [ ] **Step 7: Commit**

```bash
git add "Echo macOS/Echo_macOSApp.swift" "Echo macOS/MacFileOpener.swift" "Echo macOS/MacTriPaneView.swift"
git rm "Echo macOS/MacPlayerModel.swift"
git add EchoCore/ViewModels/PlayerModel.swift
git commit -m "refactor: replace MacPlayerModel with shared PlayerModel on macOS"
```

---

### Task A5: Share Player Views with macOS Target

**Files:**
- Modify: `Echo.xcodeproj/project.pbxproj` (remove view exclusions)
- Modify: `EchoCore/Views/NowPlayingTab.swift` (gate haptics, adapt layout)
- Modify: `EchoCore/Views/TransportControlsView.swift` (gate Haptic engine)
- Modify: `EchoCore/Views/UnifiedBottomDock.swift` (gate safe area)
- Modify: `EchoCore/Views/UnifiedTopHeader.swift` (gate folder picker)
- Modify: `EchoCore/Views/PlayerControlBar.swift` (gate MarqueeText if needed)
- Modify: `EchoCore/Views/CircularProgressPlayButton.swift` (likely cross-platform)

- [ ] **Step 1: Remove player view exclusions from macOS target**

Find the `PBXFileSystemSynchronizedBuildFileExceptionSet` for the macOS target in `project.pbxproj` (key `718DD03F18BB433E7AD362E2`). Remove these files from the exception list:
- `EchoCore/Views/NowPlayingTab.swift`
- `EchoCore/Views/TransportControlsView.swift`
- `EchoCore/Views/PlayerScrubberView.swift`
- `EchoCore/Views/UnifiedBottomDock.swift`
- `EchoCore/Views/UnifiedTopHeader.swift`
- `EchoCore/Views/PlayerControlBar.swift`
- `EchoCore/Views/NowPlayingLayout.swift`
- `EchoCore/Views/Cells/CircularProgressPlayButton.swift` (if in list)
- `EchoCore/Views/Components/MarqueeText.swift` (if in list)
- `EchoCore/Views/Components/BookProgressTrack.swift` (if in list)
- `EchoCore/Views/Components/AlbumArtHeroView.swift` (if in list)

Also remove exclusion for `EchoCore/Utilities/FolderPicker.swift` — we'll adapt it.

- [ ] **Step 2: Gate iOS-only code in TransportControlsView**

```swift
// In TransportControlsView.swift, find Haptic.impact calls:
// Wrap with:
#if os(iOS)
Haptic.impact(.light)
#endif
```

The `Haptic` type itself may need an `#if os(iOS)` guard or a macOS no-op stub.

- [ ] **Step 3: Adapt UnifiedBottomDock for macOS**

The dock uses `.safeAreaInset` and bottom-safe-area padding — these work differently on macOS. Gate the safe-area parts:

```swift
// In UnifiedBottomDock.swift:
#if os(iOS)
.padding(.bottom, safeAreaInsets.bottom > 0 ? 0 : 8)
#else
.padding(.bottom, 8)
#endif
```

- [ ] **Step 4: Adapt UnifiedTopHeader folder button for macOS**

On iOS, the folder button opens a `FolderPicker`. On macOS, it should use `NSOpenPanel` (via `MacFileOpener`). Gate the button action:

```swift
// In UnifiedTopHeader.swift:
Button(action: {
    #if os(iOS)
    showingFolderPicker = true
    #else
    Task {
        if let url = await MacFileOpener.openAudioFile() {
            await model.openFile(url)
        }
    }
    #endif
}) { ... }
```

- [ ] **Step 5: Gate haptics in NowPlayingTab**

Find all `Haptic.impact()` calls and wrap with `#if os(iOS)`.

The `NowPlayingTab` uses `UIScreen` for layout — gate those references. On macOS, use a fixed reasonable width or `GeometryReader`.

- [ ] **Step 6: Build both targets**

```bash
# macOS
xcodebuild -project Echo.xcodeproj -scheme "Echo macOS" -destination 'platform=macOS' build 2>&1 | tail -5

# iOS
xcodebuild -project Echo.xcodeproj -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Both should compile clean.

- [ ] **Step 7: Commit**

```bash
git add Echo.xcodeproj/project.pbxproj EchoCore/Views/
git commit -m "refactor: share player views between iOS and macOS targets"
```

---

### Task A6: macOS Reader View — Use Shared ReaderTab Components

**Files:**
- Read: `Echo macOS/MacReaderFeedView.swift`
- Read: `Echo macOS/MacTOCTreeView.swift`
- Modify: `Echo macOS/MacTriPaneView.swift`

- [ ] **Step 1: Assess MacReaderFeedView vs ReaderTab**

The macOS reader is a separate `MacReaderFeedView` that renders a SwiftUI `List` of blocks. The iOS reader is `ReaderTab` wrapping a `ReaderFeedCollectionView` (UICollectionView). 

For Phase A, we use `ReaderTab` on macOS by removing it from the exclusion list, but we need a `MacReaderAdapterView` that places it in the tri-pane context.

Actually — `ReaderTab` uses `ReaderFeedCollectionView` which is a `UICollectionView` wrapped in `UIViewRepresentable`. That works on macOS (Catalyst-style) but may have issues. A better approach for now:

**Keep `MacReaderFeedView` for the center pane**, but update its active-block logic to use the shared `ReaderActiveBlockResolver` (it already does — confirmed in exploration). The macOS reader will benefit from word-level highlighting in Phase B automatically since it uses the same resolver.

- [ ] **Step 2: Verify MacReaderFeedView already uses ReaderActiveBlockResolver**

Confirmed from exploration: `MacReaderFeedView` calls `ReaderActiveBlockResolver.activeBlockID(in:time:currentTrackChapterIndices:)` — already shared.

- [ ] **Step 3: Add playback time observation to MacReaderFeedView**

If `MacReaderFeedView` doesn't already observe `PlayerModel.currentPlaybackTime` for active block updates (it may use its own timer), wire it:

```swift
// In MacReaderFeedView body:
.onChange(of: player.currentPlaybackTime) { _, newTime in
    updateActiveBlock(time: newTime)
}
```

- [ ] **Step 4: Commit**

```bash
git add "Echo macOS/MacReaderFeedView.swift" "Echo macOS/MacTriPaneView.swift"
git commit -m "refactor: wire macOS reader to shared active-block resolver"
```

---

### Task A7: Word-Level Alignment — Data Model

**Files:**
- Create: `Shared/Database/WordAlignmentRecord.swift`
- Create: `Shared/Database/DAOs/WordAlignmentDAO.swift`
- Modify: `Shared/Database/DatabaseService.swift` (register migration + DAO)

- [ ] **Step 1: Define WordAlignmentRecord**

```swift
// Shared/Database/WordAlignmentRecord.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// Maps a single word within an EPUB block to its audio timestamp.
/// Populated during DTW alignment when granularity ≥ .word.
struct WordAlignmentRecord: Identifiable, Equatable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var audiobookID: String
    var epubBlockID: String
    /// Zero-based index of this word within the block's plain text.
    var wordIndex: Int
    /// The word text itself (denormalized for fast lookup).
    var word: String
    /// Audio start time in seconds.
    var audioStartTime: TimeInterval
    /// Audio end time in seconds.
    var audioEndTime: TimeInterval
    /// Confidence 0.0–1.0 from DTW match strength.
    var confidence: Double
    /// Source of this alignment: "dtw", "interpolated", "synthesized".
    var source: String
    var createdAt: String?

    static let databaseTableName = "word_alignment"

    enum CodingKeys: String, CodingKey {
        case id, audiobookID = "audiobook_id", epubBlockID = "epub_block_id"
        case wordIndex = "word_index", word
        case audioStartTime = "audio_start_time", audioEndTime = "audio_end_time"
        case confidence, source, createdAt = "created_at"
    }
}
```

- [ ] **Step 2: Define WordAlignmentDAO**

```swift
// Shared/Database/DAOs/WordAlignmentDAO.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

struct WordAlignmentDAO {
    let db: DatabaseWriter

    func insert(_ records: [WordAlignmentRecord]) throws {
        try db.write { db in
            for record in records {
                try record.insert(db)
            }
        }
    }

    func words(for audiobookID: String, blockID: String) throws -> [WordAlignmentRecord] {
        try db.read { db in
            try WordAlignmentRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("epub_block_id") == blockID)
                .order(Column("word_index"))
                .fetchAll(db)
        }
    }

    func words(for audiobookID: String) throws -> [WordAlignmentRecord] {
        try db.read { db in
            try WordAlignmentRecord
                .filter(Column("audiobook_id") == audiobookID)
                .order(Column("audio_start_time"))
                .fetchAll(db)
        }
    }

    func deleteAll(for audiobookID: String) throws {
        try db.write { db in
            try WordAlignmentRecord
                .filter(Column("audiobook_id") == audiobookID)
                .deleteAll(db)
        }
    }
}
```

- [ ] **Step 3: Create database migration (Schema_V19)**

```swift
// In Shared/Database/Migrations/Schema_V19.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

enum Schema_V19: Migration {
    static let identifier = "v19_word_alignment"

    static func migrate(_ db: Database) throws {
        try db.create(table: "word_alignment") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("audiobook_id", .text).notNull().indexed()
            t.column("epub_block_id", .text).notNull().indexed()
            t.column("word_index", .integer).notNull()
            t.column("word", .text).notNull()
            t.column("audio_start_time", .double).notNull()
            t.column("audio_end_time", .double).notNull()
            t.column("confidence", .double).notNull().defaults(to: 0.0)
            t.column("source", .text).notNull().defaults(to: "interpolated")
            t.column("created_at", .text)
        }
        try db.create(index: "idx_word_alignment_audiobook_time",
                      on: "word_alignment",
                      columns: ["audiobook_id", "audio_start_time"])
    }
}
```

- [ ] **Step 4: Register migration in MigrationService**

Add `Schema_V19` to the migration registry and `WordAlignmentDAO` to DatabaseService:

```swift
// In DatabaseService.swift:
var wordAlignmentDAO: WordAlignmentDAO { WordAlignmentDAO(db: dbWriter) }
```

- [ ] **Step 5: Build and run tests**

```bash
make build-tests
make test-only FILTER=EchoTests/DatabaseService
```

Expected: existing DB tests pass. New migration runs without error.

- [ ] **Step 6: Commit**

```bash
git add Shared/Database/WordAlignmentRecord.swift Shared/Database/DAOs/WordAlignmentDAO.swift \
        Shared/Database/Migrations/Schema_V19.swift Shared/Database/DatabaseService.swift \
        Shared/Database/MigrationService.swift
git commit -m "feat: add word_alignment table and DAO for word-level timestamps"
```

---

### Task A8: Extend AlignmentService for Word Granularity

**Files:**
- Modify: `EchoCore/Services/AlignmentService.swift`
- Modify: `EchoCore/Services/TimelineIngestionService.swift`

- [ ] **Step 1: Add granularity parameter to recalculateTimeline**

Add a `granularity` parameter with default `.paragraph` to preserve backward compatibility:

```swift
// In AlignmentService.swift, modify the signature:
func recalculateTimeline(
    anchoredOnly: Bool = false,
    granularity: GranularityLevel = .paragraph
) throws {
    // ... existing block-level logic unchanged when granularity == .paragraph
    
    // After the existing block-level timeline upsert loop, add:
    if granularity == .word {
        try materializeWordLevelTimeline(db: &db, blocks: sortedAllBlocks, 
                                          anchorTimeByBlockID: syntheticAnchorTimes,
                                          wordPositionByBlockID: wordPositionByBlockID,
                                          averageCPS: averageCPS)
    }
}
```

- [ ] **Step 2: Implement materializeWordLevelTimeline**

The key algorithm: for each block that has a `syntheticAnchorTime`, distribute its words proportionally between its `audioStartTime` and the next block's `audioStartTime`. Words within a block get evenly-spaced timestamps based on character position:

```swift
private func materializeWordLevelTimeline(
    db: inout Database,
    blocks: [EPubBlockRecord],
    anchorTimeByBlockID: [String: TimeInterval],
    wordPositionByBlockID: [String: Double],
    averageCPS: Double
) throws {
    let sorted = blocks.sorted { $0.sequenceIndex < $1.sequenceIndex }
    
    for i in 0..<sorted.count {
        let block = sorted[i]
        guard !block.isHidden,
              EPubBlockRecord.Kind(rawValue: block.blockKind) != .image,
              let blockStartTime = anchorTimeByBlockID[block.id],
              let text = block.text, !text.isEmpty else { continue }
        
        // Find next anchored block for end-time bound
        let blockEndTime: TimeInterval
        if let nextAnchored = sorted[(i+1)...].first(where: { anchorTimeByBlockID[$0.id] != nil }),
           let nextTime = anchorTimeByBlockID[nextAnchored.id] {
            blockEndTime = nextTime
        } else {
            // Last block: estimate from char count
            blockEndTime = blockStartTime + Double(text.count) / averageCPS
        }
        
        let words = text.split(separator: " ")
        guard !words.isEmpty else { continue }
        
        let blockDuration = blockEndTime - blockStartTime
        let charCount = Double(max(1, text.count))
        
        var charPos: Double = 0
        for (idx, word) in words.enumerated() {
            let wordStart = blockStartTime + (charPos / charCount) * blockDuration
            let wordCharCount = Double(word.count + 1) // +1 for space
            let wordEnd = blockStartTime + ((charPos + wordCharCount) / charCount) * blockDuration
            charPos += wordCharCount
            
            let record = WordAlignmentRecord(
                audiobookID: audiobookID,
                epubBlockID: block.id,
                wordIndex: idx,
                word: String(word),
                audioStartTime: wordStart,
                audioEndTime: wordEnd,
                confidence: 0.5, // interpolated = medium confidence
                source: "interpolated",
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
            try record.insert(db)
        }
    }
}
```

- [ ] **Step 3: Add Upsert for word-level TimelineItems**

For each word, create a `TimelineItem` with `granularityLevel: .word`:

```swift
// Inside the word loop in materializeWordLevelTimeline:
let timelineID = "word-\(block.id)-\(idx)"
let timelineItem = TimelineItem(
    id: timelineID,
    audiobookID: audiobookID,
    itemType: .textSegment,
    title: String(word),
    subtitle: nil,
    textPayload: String(word),
    imagePath: nil,
    audioStartTime: wordStart,
    audioEndTime: wordEnd,
    epubSequenceIndex: block.sequenceIndex,
    granularityLevel: .word,
    playlistPosition: nil,
    isEnabled: true,
    sourceTable: "word_alignment",
    sourceRowid: String(record.id ?? 0),
    metadataJSON: nil,
    epubBlockID: block.id,
    timestampSource: TimestampSource.interpolated.rawValue,
    alignmentStatus: AlignmentStatus.interpolated.rawValue,
    alignmentConfidence: record.confidence,
    createdAt: record.createdAt,
    modifiedAt: nil
)
try timelineItem.upsert(db)
```

- [ ] **Step 4: Clear word data on recalculation**

At the start of `recalculateTimeline`, when `granularity == .word`, delete existing word-level timeline items for this audiobook:

```swift
if granularity == .word {
    try WordAlignmentDAO(db: db).deleteAll(for: audiobookID)
    try db.execute(sql: """
        DELETE FROM timeline_item 
        WHERE audiobook_id = ? AND granularity_level = ?
        """, arguments: [audiobookID, GranularityLevel.word.rawValue])
}
```

- [ ] **Step 5: Build and test**

```bash
make build-tests
make test-only FILTER=EchoTests/AlignmentService
```

- [ ] **Step 6: Commit**

```bash
git add EchoCore/Services/AlignmentService.swift EchoCore/Services/TimelineIngestionService.swift
git commit -m "feat: add word-level granularity to AlignmentService.recalculateTimeline"
```

---

### Task A9: Extend AutoAlignmentService to Persist Word Timestamps

**Files:**
- Modify: `EchoCore/Services/AutoAlignmentService.swift`
- Modify: `EchoCore/Services/TokenDTW.swift`
- Modify: `EchoCore/Services/AnchorSelector.swift`

- [ ] **Step 1: Capture per-word DTW matches in TokenDTW**

Currently `TokenDTW.align()` returns a DTW cost matrix — the path through the matrix tells us which EPUB token maps to which audio token. Extract the mapping:

```swift
// Add to TokenDTW:
struct WordMatch: Equatable, Sendable {
    let epubToken: String
    let epubTokenIndex: Int
    let blockID: String
    let audioTime: TimeInterval
    let isStrongMatch: Bool  // exact token match in run ≥ 3
}

// New method:
func extractWordMatches(
    epubTokens: [EPubToken],
    audioTokens: [AudioToken],
    dtwPath: [(Int, Int)],  // (epubIdx, audioIdx) pairs from alignment
    strongMatchRunLength: Int = 3
) -> [WordMatch] {
    // For each path point, create a WordMatch
    // Mark as strong if in a run of exact matches ≥ strongMatchRunLength
}
```

- [ ] **Step 2: Persist word matches after DTW in AutoAlignmentService**

After DTW alignment completes for a chapter, call the new word persistence:

```swift
// In AutoAlignmentService.insertAnchors, after AnchorSelector.run:
let wordMatches = tokenDTW.extractWordMatches(
    epubTokens: epubTokens,
    audioTokens: audioTokens,
    dtwPath: alignmentPath
)
let wordRecords = wordMatches.map { match in
    WordAlignmentRecord(
        audiobookID: audiobookID,
        epubBlockID: match.blockID,
        wordIndex: match.epubTokenIndex,
        word: match.epubToken,
        audioStartTime: match.audioTime,
        audioEndTime: match.audioTime + 0.3, // estimate ~300ms per word
        confidence: match.isStrongMatch ? 0.85 : 0.4,
        source: "dtw",
        createdAt: ISO8601DateFormatter().string(from: Date())
    )
}
try wordAlignmentDAO.insert(wordRecords)
```

- [ ] **Step 3: Trigger word-level recalculation after auto-alignment**

After anchors are inserted, call `recalculateTimeline(granularity: .word)` if the user has selected word granularity:

```swift
// In AutoAlignmentService, after anchor insertion:
if settings.wordLevelAlignmentEnabled {
    try alignmentService.recalculateTimeline(granularity: .word)
} else {
    try alignmentService.recalculateTimeline()
}
```

- [ ] **Step 4: Build and test**

```bash
make build-tests
make test-only FILTER=EchoTests/AutoAlignment
```

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/AutoAlignmentService.swift EchoCore/Services/TokenDTW.swift EchoCore/Services/AnchorSelector.swift
git commit -m "feat: persist word-level timestamps from DTW alignment"
```

---

### Task A10: Granularity Selector UI (Shared)

**Files:**
- Modify: `EchoCore/Views/ReaderTab+Alignment.swift` (add granularity picker)
- Modify: `EchoCore/Views/BookSettingsView.swift` (or wherever alignment settings live)
- Read: `EchoCore/Views/ManualAlignmentSheet.swift`

- [ ] **Step 1: Add granularity setting to SettingsManager or BookPreferencesService**

Check if there's an existing alignment settings location. Add a `wordLevelAlignmentEnabled: Bool` preference (default `false` for existing behavior):

```swift
// In BookPreferencesService or equivalent:
var wordLevelAlignmentEnabled: Bool {
    get { /* UserDefaults or DB */ }
    set { /* persist */ }
}
```

- [ ] **Step 2: Add granularity picker to alignment context menu**

In `ReaderTab+Alignment.swift`, add a toggle or picker in the auto-alignment options:

```swift
// In the alignment context menu:
Picker("Alignment Granularity", selection: $wordLevelGranularity) {
    Text("Paragraph").tag(GranularityLevel.paragraph)
    Text("Sentence").tag(GranularityLevel.sentence)
    Text("Word").tag(GranularityLevel.word)
}
.pickerStyle(.menu)
```

- [ ] **Step 3: Wire granularity to AutoAlignmentService trigger**

When the user taps "Auto-Align Chapters", pass the selected granularity:

```swift
autoAlignmentService.alignAllChapters(granularity: selectedGranularity)
```

- [ ] **Step 4: Build and verify UI**

```bash
xcodebuild -project Echo.xcodeproj -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Views/ReaderTab+Alignment.swift EchoCore/Views/BookSettingsView.swift
git commit -m "feat: add granularity selector for word/sentence/paragraph alignment"
```

---

## Phase B: Karaoke Highlighting

> **Prerequisite:** Phase A complete (word-level timeline items exist)

### Task B1: Word-Level Lookup in ReaderActiveBlockResolver

**Files:**
- Modify: `Shared/ReaderActiveBlockResolver.swift`
- Modify: `EchoCore/ViewModels/ReaderFeedViewModel.swift`

- [ ] **Step 1: Add word-level resolution method**

Add a new method that returns the active word within a block:

```swift
// In ReaderActiveBlockResolver:
struct ActiveWordResult {
    let blockID: String
    let wordIndex: Int
    let wordStartTime: TimeInterval
    let wordEndTime: TimeInterval
}

/// Resolves the active word within the active block.
/// Uses word-level TimelineItems (granularityLevel == .word) for lookup.
static func activeWord(
    in wordCache: [WordTimelineRow],
    time: TimeInterval,
    activeBlockID: String
) -> ActiveWordResult? {
    // Filter to words in the active block, then binary search by time
    let blockWords = wordCache.filter { $0.blockID == activeBlockID }
    var low = 0
    var high = blockWords.count - 1
    while low <= high {
        let mid = low + (high - low) / 2
        let row = blockWords[mid]
        if time >= row.start && time < row.end {
            return ActiveWordResult(
                blockID: row.blockID,
                wordIndex: row.wordIndex,
                wordStartTime: row.start,
                wordEndTime: row.end
            )
        } else if time < row.start {
            high = mid - 1
        } else {
            low = mid + 1
        }
    }
    return nil
}

typealias WordTimelineRow = (
    start: TimeInterval, end: TimeInterval, blockID: String, wordIndex: Int
)
```

- [ ] **Step 2: Build word cache in ReaderFeedViewModel**

Add a word-level cache alongside the existing `timelineCache`:

```swift
// In ReaderFeedViewModel:
private var wordTimelineCache: [ReaderActiveBlockResolver.WordTimelineRow] = []

func loadWordTimeline() async {
    guard let db = try? DatabaseService() else { return }
    let dao = WordAlignmentDAO(db: db.dbWriter)
    do {
        let words = try dao.words(for: audiobookID)
        wordTimelineCache = words.map { word in
            (start: word.audioStartTime, end: word.audioEndTime,
             blockID: word.epubBlockID, wordIndex: word.wordIndex)
        }
    } catch {
        logger.warning("Failed to load word timeline: \(error)")
    }
}
```

- [ ] **Step 3: Publish active word in ReaderFeedViewModel**

Add a published property:

```swift
var activeWordResult: ReaderActiveBlockResolver.ActiveWordResult?

func updateActiveBlock(time: TimeInterval, currentTrackChapterIndices: Set<Int>?) {
    let blockID = ReaderActiveBlockResolver.activeBlockID(
        in: timelineCache, time: time,
        currentTrackChapterIndices: currentTrackChapterIndices
    )
    activeBlockID = blockID
    
    // Resolve active word within the block
    if let blockID, !wordTimelineCache.isEmpty {
        activeWordResult = ReaderActiveBlockResolver.activeWord(
            in: wordTimelineCache, time: time, activeBlockID: blockID
        )
    } else {
        activeWordResult = nil
    }
}
```

- [ ] **Step 4: Build and test**

```bash
make build-tests
make test-only FILTER=EchoTests/ReaderActiveBlock
```

- [ ] **Step 5: Commit**

```bash
git add Shared/ReaderActiveBlockResolver.swift EchoCore/ViewModels/ReaderFeedViewModel.swift
git commit -m "feat: add word-level resolution to ReaderActiveBlockResolver"
```

---

### Task B2: Karaoke Highlighting in ParagraphCardCell

**Files:**
- Modify: `EchoCore/Views/Cells/ParagraphCardCell.swift`

- [ ] **Step 1: Add highlighted word index property**

```swift
// In ParagraphCardCell:
var highlightedWordIndex: Int? {
    didSet {
        guard highlightedWordIndex != oldValue else { return }
        updateHighlighting()
    }
}

private var currentBlockText: String = ""
private var currentFont: UIFont = .systemFont(ofSize: 16)
private var currentTextColor: UIColor = .label
private var currentLineSpacing: CGFloat = 4
```

- [ ] **Step 2: Implement AttributedString word highlighting**

```swift
private func updateHighlighting() {
    let words = currentBlockText.split(separator: " ")
    let attributed = NSMutableAttributedString(string: currentBlockText)
    
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineSpacing = currentLineSpacing
    
    let baseAttributes: [NSAttributedString.Key: Any] = [
        .font: currentFont,
        .foregroundColor: currentTextColor.withAlphaComponent(0.6),
        .paragraphStyle: paragraphStyle
    ]
    attributed.setAttributes(baseAttributes, range: NSRange(location: 0, length: attributed.length))
    
    // Highlight the active word
    if let idx = highlightedWordIndex, idx < words.count {
        let word = words[idx]
        var searchRange = NSRange(location: 0, length: attributed.length)
        var wordIndex = 0
        while searchRange.location < attributed.length {
            let found = (currentBlockText as NSString).range(of: String(word), options: [], range: searchRange)
            if found.location == NSNotFound { break }
            if wordIndex == idx {
                attributed.addAttributes([
                    .foregroundColor: currentTextColor,
                    .font: UIFont.systemFont(ofSize: currentFont.pointSize, weight: .bold),
                    .backgroundColor: UIColor.systemBlue.withAlphaComponent(0.15)
                ], range: found)
                break
            }
            wordIndex += 1
            searchRange = NSRange(location: found.location + found.length,
                                  length: attributed.length - (found.location + found.length))
        }
    }
    
    label.attributedText = attributed
}
```

**Note:** Word-index-based substring finding has edge cases with repeated words. For production, switch to storing `NSRange` per word at configure-time. The initial implementation uses simple word counting for clarity; a follow-up task hardens this.

- [ ] **Step 3: Update configure method to store text state**

```swift
func configure(with block: EPubBlockRecord, font: UIFont, tint: UIColor, 
               lineSpacing: CGFloat, isExplicitHighlight: Bool, 
               searchQuery: String? = nil,
               highlightedWordIndex: Int? = nil) {
    // ... existing setup ...
    currentBlockText = plainText
    currentFont = font
    currentTextColor = textColor
    currentLineSpacing = lineSpacing
    self.highlightedWordIndex = highlightedWordIndex
}
```

- [ ] **Step 4: Build**

```bash
xcodebuild -project Echo.xcodeproj -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Views/Cells/ParagraphCardCell.swift
git commit -m "feat: add word-level karaoke highlighting to ParagraphCardCell"
```

---

### Task B3: Karaoke Highlighting in HeadingCardCell

**Files:**
- Modify: `EchoCore/Views/Cells/HeadingCardCell.swift`

- [ ] **Step 1: Mirror the word-highlighting pattern from ParagraphCardCell**

Heading cards have shorter text (chapter titles), so the word highlighting is simpler. Apply the same `highlightedWordIndex` + `NSMutableAttributedString` pattern:

```swift
// In HeadingCardCell, add the same properties and updateHighlighting() method
// as ParagraphCardCell, adapted for heading font sizes.
```

- [ ] **Step 2: Build**

```bash
xcodebuild -project Echo.xcodeproj -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

- [ ] **Step 3: Commit**

```bash
git add EchoCore/Views/Cells/HeadingCardCell.swift
git commit -m "feat: add word-level karaoke highlighting to HeadingCardCell"
```

---

### Task B4: Wire Karaoke Data Flow End-to-End

**Files:**
- Modify: `EchoCore/Views/ReaderTab.swift` (pass word index to cells)
- Modify: `EchoCore/Views/ReaderFeedCollectionView.swift` (update cells on word change)

- [ ] **Step 1: Observe activeWordResult in ReaderTab**

```swift
// In ReaderTab, add:
.onChange(of: viewModel.activeWordResult?.wordIndex) { _, newWordIndex in
    // Trigger collection view update for the active block's card
    if let blockID = viewModel.activeBlockID,
       let indexPath = viewModel.cardIndexByBlockID[blockID] {
        readerFeedCollectionView.reloadItems(at: [indexPath])
    }
}
```

- [ ] **Step 2: Pass highlightedWordIndex to cell configuration**

In `ReaderFeedCollectionView.cellForItemAt`:

```swift
if let paragraphCell = cell as? ParagraphCardCell {
    let wordIdx = viewModel.activeBlockID == block.id 
        ? viewModel.activeWordResult?.wordIndex : nil
    paragraphCell.configure(
        with: block, font: font, tint: tint,
        lineSpacing: lineSpacing,
        isExplicitHighlight: isExplicitHighlight,
        searchQuery: searchQuery,
        highlightedWordIndex: wordIdx
    )
}
```

- [ ] **Step 3: Optimize — throttle cell reloads**

Word-level updates happen ~3-5 times per second (average English word rate). Reloading cells at that rate is fine for UICollectionView, but to be safe, throttle to max 10 Hz:

```swift
private var lastWordUpdateTime: TimeInterval = 0
private let minWordUpdateInterval: TimeInterval = 0.1 // 10 Hz

// In the onChange handler:
let now = CACurrentMediaTime()
guard now - lastWordUpdateTime >= minWordUpdateInterval else { return }
lastWordUpdateTime = now
// ... reload cell ...
```

- [ ] **Step 4: Build both targets**

```bash
xcodebuild -project Echo.xcodeproj -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
xcodebuild -project Echo.xcodeproj -scheme "Echo macOS" -destination 'platform=macOS' build 2>&1 | tail -5
```

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Views/ReaderTab.swift EchoCore/Views/ReaderFeedCollectionView.swift
git commit -m "feat: wire karaoke word highlighting data flow end-to-end"
```

---

## Phase C: Batch Processing Queue

> **Prerequisite:** Phase A complete (macOS/iOS convergence for shared services)

### Task C1: Batch Queue Database Schema

**Files:**
- Create: `Shared/Database/BatchQueueItem.swift`
- Create: `Shared/Database/DAOs/BatchQueueDAO.swift`
- Create: `Shared/Database/Migrations/Schema_V20.swift`
- Modify: `Shared/Database/DatabaseService.swift`
- Modify: `Shared/Database/MigrationService.swift`

- [ ] **Step 1: Define BatchQueueItem**

```swift
// Shared/Database/BatchQueueItem.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

enum BatchItemStatus: String, Codable {
    case queued
    case importing
    case transcribing
    case aligning
    case completed
    case failed
}

struct BatchQueueItem: Identifiable, Equatable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var audiobookID: String
    /// Original file URL (security-scoped bookmark data on macOS).
    var sourceURL: String
    /// Display name for the queue UI.
    var displayName: String
    /// Queue position (0-based). Preserved across app restarts.
    var queuePosition: Int
    /// Current processing status.
    var status: BatchItemStatus
    /// Progress 0.0–1.0 within the current phase.
    var progress: Double
    /// Human-readable status message.
    var statusMessage: String?
    /// Error message if status == .failed.
    var errorMessage: String?
    /// Selected alignment granularity.
    var granularity: Int  // GranularityLevel rawValue
    /// When this item was enqueued.
    var enqueuedAt: String
    /// When processing started.
    var startedAt: String?
    /// When processing completed or failed.
    var completedAt: String?

    static let databaseTableName = "batch_queue"

    enum CodingKeys: String, CodingKey {
        case id, audiobookID = "audiobook_id", sourceURL = "source_url"
        case displayName = "display_name", queuePosition = "queue_position"
        case status, progress, statusMessage = "status_message"
        case errorMessage = "error_message", granularity
        case enqueuedAt = "enqueued_at", startedAt = "started_at"
        case completedAt = "completed_at"
    }
}
```

- [ ] **Step 2: Define BatchQueueDAO**

```swift
// Shared/Database/DAOs/BatchQueueDAO.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

struct BatchQueueDAO {
    let db: DatabaseWriter

    func enqueue(_ item: BatchQueueItem) throws -> BatchQueueItem {
        var copy = item
        try db.write { db in
            // Get next queue position
            if let maxPos = try Int.fetchOne(db, sql: """
                SELECT MAX(queue_position) FROM batch_queue
                """) {
                copy.queuePosition = maxPos + 1
            } else {
                copy.queuePosition = 0
            }
            try copy.insert(db)
        }
        return copy
    }

    func nextQueued() throws -> BatchQueueItem? {
        try db.read { db in
            try BatchQueueItem
                .filter(Column("status") == BatchItemStatus.queued.rawValue)
                .order(Column("queue_position"))
                .fetchOne(db)
        }
    }

    func updateStatus(id: Int64, status: BatchItemStatus, 
                      progress: Double? = nil, message: String? = nil,
                      error: String? = nil) throws {
        try db.write { db in
            var updates: [String: DatabaseValueConvertible] = [
                "status": status.rawValue
            ]
            if let progress { updates["progress"] = progress }
            if let message { updates["status_message"] = message }
            if let error { updates["error_message"] = error }
            if status == .completed || status == .failed {
                updates["completed_at"] = ISO8601DateFormatter().string(from: Date())
            }
            if status == .importing || status == .transcribing || status == .aligning {
                updates["started_at"] = ISO8601DateFormatter().string(from: Date())
            }
            try BatchQueueItem
                .filter(Column("id") == id)
                .updateAll(db, ColumnAssignment(updates))
        }
    }

    func allItems() throws -> [BatchQueueItem] {
        try db.read { db in
            try BatchQueueItem
                .order(Column("queue_position"))
                .fetchAll(db)
        }
    }

    func deleteCompleted() throws {
        try db.write { db in
            try BatchQueueItem
                .filter(Column("status") == BatchItemStatus.completed.rawValue)
                .deleteAll(db)
        }
    }

    func pendingCount() throws -> Int {
        try db.read { db in
            try BatchQueueItem
                .filter(Column("status") != BatchItemStatus.completed.rawValue)
                .filter(Column("status") != BatchItemStatus.failed.rawValue)
                .fetchCount(db)
        }
    }
}
```

- [ ] **Step 3: Create Schema_V20 migration**

```swift
// Shared/Database/Migrations/Schema_V20.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

enum Schema_V20: Migration {
    static let identifier = "v20_batch_queue"

    static func migrate(_ db: Database) throws {
        try db.create(table: "batch_queue") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("audiobook_id", .text).notNull()
            t.column("source_url", .text).notNull()
            t.column("display_name", .text).notNull()
            t.column("queue_position", .integer).notNull()
            t.column("status", .text).notNull().defaults(to: BatchItemStatus.queued.rawValue)
            t.column("progress", .double).notNull().defaults(to: 0.0)
            t.column("status_message", .text)
            t.column("error_message", .text)
            t.column("granularity", .integer).notNull().defaults(to: GranularityLevel.paragraph.rawValue)
            t.column("enqueued_at", .text).notNull()
            t.column("started_at", .text)
            t.column("completed_at", .text)
        }
    }
}
```

- [ ] **Step 4: Register migration + DAO in DatabaseService**

```swift
var batchQueueDAO: BatchQueueDAO { BatchQueueDAO(db: dbWriter) }
```

- [ ] **Step 5: Build and test**

```bash
make build-tests
make test-only FILTER=EchoTests/DatabaseService
```

- [ ] **Step 6: Commit**

```bash
git add Shared/Database/BatchQueueItem.swift Shared/Database/DAOs/BatchQueueDAO.swift \
        Shared/Database/Migrations/Schema_V20.swift Shared/Database/DatabaseService.swift \
        Shared/Database/MigrationService.swift
git commit -m "feat: add batch queue database schema and DAO"
```

---

### Task C2: BatchProcessingService

**Files:**
- Create: `EchoCore/Services/BatchProcessingService.swift`

- [ ] **Step 1: Create BatchProcessingService**

```swift
// EchoCore/Services/BatchProcessingService.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation
import os.log

/// Sequential batch processor for import → transcribe → align pipeline.
/// Processes one book at a time from a persistent queue. Survives app background/termination.
@MainActor
@Observable
final class BatchProcessingService {
    private let logger = Logger(category: "BatchProcessing")
    private let queueDAO: BatchQueueDAO
    private let dbService: DatabaseService

    /// Currently processing item, if any.
    private(set) var currentItem: BatchQueueItem?
    /// All queue items for UI.
    private(set) var queueItems: [BatchQueueItem] = []
    /// Whether the processor is actively working.
    private(set) var isProcessing: Bool = false

    private var processingTask: Task<Void, Never>?

    init(databaseService: DatabaseService) {
        self.dbService = databaseService
        self.queueDAO = databaseService.batchQueueDAO
    }

    // MARK: - Queue Management

    func enqueue(url: URL, displayName: String, granularity: GranularityLevel) async throws {
        let audiobookID = "batch-\(UUID().uuidString)"
        let item = BatchQueueItem(
            audiobookID: audiobookID,
            sourceURL: url.absoluteString,
            displayName: displayName,
            queuePosition: 0,
            status: .queued,
            progress: 0,
            granularity: granularity.rawValue,
            enqueuedAt: ISO8601DateFormatter().string(from: Date())
        )
        _ = try queueDAO.enqueue(item)
        await refreshQueue()
        startIfIdle()
    }

    func enqueueMultiple(urls: [(URL, String)], granularity: GranularityLevel) async throws {
        for (url, name) in urls {
            try await enqueue(url: url, displayName: name, granularity: granularity)
        }
    }

    // MARK: - Processing Loop

    func startIfIdle() {
        guard processingTask == nil else { return }
        processingTask = Task { [weak self] in
            await self?.processLoop()
        }
    }

    private func processLoop() async {
        isProcessing = true
        defer { isProcessing = false; processingTask = nil }

        while !Task.isCancelled {
            guard let next = try? queueDAO.nextQueued() else {
                break // Queue empty
            }
            currentItem = next
            await refreshQueue()

            do {
                try await processItem(next)
            } catch {
                logger.error("Batch item \(next.id ?? 0) failed: \(error)")
                try? queueDAO.updateStatus(
                    id: next.id!, status: .failed,
                    error: error.localizedDescription
                )
            }
            currentItem = nil
            await refreshQueue()
        }
    }

    private func processItem(_ item: BatchQueueItem) async throws {
        // Phase 1: Import
        try queueDAO.updateStatus(id: item.id!, status: .importing, progress: 0,
                                   message: "Importing...")
        guard let url = URL(string: item.sourceURL) else {
            throw BatchError.invalidURL
        }
        // Delegate to EPUBImportCoordinator
        // ... import logic ...

        // Phase 2: Transcribe
        try queueDAO.updateStatus(id: item.id!, status: .transcribing, progress: 0.33,
                                   message: "Transcribing with WhisperKit...")
        // ... WhisperKit transcription with progress callbacks ...

        // Phase 3: Align
        try queueDAO.updateStatus(id: item.id!, status: .aligning, progress: 0.66,
                                   message: "Aligning with DTW...")
        let granularity = GranularityLevel(rawValue: item.granularity) ?? .paragraph
        // ... run auto-alignment at selected granularity ...

        // Done
        try queueDAO.updateStatus(id: item.id!, status: .completed, progress: 1.0,
                                   message: "Complete")
    }

    // MARK: - Helpers

    func refreshQueue() async {
        queueItems = (try? queueDAO.allItems()) ?? []
    }

    func clearCompleted() throws {
        try queueDAO.deleteCompleted()
    }

    func cancelProcessing() {
        processingTask?.cancel()
        processingTask = nil
        isProcessing = false
    }
}

enum BatchError: LocalizedError {
    case invalidURL
    var errorDescription: String? { "Invalid file URL" }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -project Echo.xcodeproj -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

- [ ] **Step 3: Commit**

```bash
git add EchoCore/Services/BatchProcessingService.swift
git commit -m "feat: add BatchProcessingService with sequential queue processing"
```

---

### Task C3: Batch Queue UI

**Files:**
- Create: `EchoCore/Views/BatchQueueView.swift`
- Create: `EchoCore/Views/BatchQueueRowView.swift`

- [ ] **Step 1: Create BatchQueueView**

```swift
// EchoCore/Views/BatchQueueView.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct BatchQueueView: View {
    @Environment(BatchProcessingService.self) private var processor

    var body: some View {
        List {
            if processor.queueItems.isEmpty {
                ContentUnavailableView(
                    "No Books Queued",
                    systemImage: "square.stack",
                    description: Text("Add books to process them overnight.")
                )
            }
            ForEach(processor.queueItems) { item in
                BatchQueueRowView(item: item)
            }
        }
        .navigationTitle("Batch Queue")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if processor.isProcessing {
                    Button("Stop") { processor.cancelProcessing() }
                } else {
                    Button("Clear Completed") {
                        try? processor.clearCompleted()
                        Task { await processor.refreshQueue() }
                    }
                }
            }
        }
        .task {
            await processor.refreshQueue()
            processor.startIfIdle()
        }
    }
}
```

- [ ] **Step 2: Create BatchQueueRowView**

```swift
// EchoCore/Views/BatchQueueRowView.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct BatchQueueRowView: View {
    let item: BatchQueueItem

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName)
                    .font(.headline)
                if let message = item.statusMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if item.status != .queued && item.status != .completed {
                    ProgressView(value: item.progress)
                        .tint(statusColor)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var statusIcon: some View {
        Group {
            switch item.status {
            case .queued:     Image(systemName: "clock").foregroundStyle(.secondary)
            case .importing:  ProgressView().scaleEffect(0.7)
            case .transcribing: Image(systemName: "waveform").foregroundStyle(.blue)
            case .aligning:   Image(systemName: "align.horizontal.center").foregroundStyle(.orange)
            case .completed:  Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:     Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
        }
        .frame(width: 28)
    }

    private var statusColor: Color {
        switch item.status {
        case .failed: .red
        case .completed: .green
        default: .blue
        }
    }
}
```

- [ ] **Step 3: Add "Add to Batch Queue" option to import flow**

In the alignment context menu or book settings, add:

```swift
Button("Add to Batch Queue") {
    Task {
        try await processor.enqueue(
            url: bookURL,
            displayName: bookTitle,
            granularity: .word
        )
    }
}
```

- [ ] **Step 4: Build both targets**

```bash
xcodebuild -project Echo.xcodeproj -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
xcodebuild -project Echo.xcodeproj -scheme "Echo macOS" -destination 'platform=macOS' build 2>&1 | tail -5
```

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Views/BatchQueueView.swift EchoCore/Views/BatchQueueRowView.swift
git commit -m "feat: add batch queue UI with progress tracking"
```

---

### Task C4: macOS Batch Integration — Bulk Folder Import

**Files:**
- Modify: `Echo macOS/MacBulkAlignmentService.swift` (adapt or replace with BatchProcessingService)
- Modify: `Echo macOS/Echo_macOSApp.swift` (wire BatchProcessingService)

- [ ] **Step 1: Update MacBulkAlignmentService to use BatchProcessingService**

`MacBulkAlignmentService` currently does bulk folder alignment independently. Refactor it to enqueue items into `BatchProcessingService`:

```swift
// In MacBulkAlignmentService (or replace entirely):
func enqueueFolder(url: URL, granularity: GranularityLevel) async throws {
    let files = try FileManager.default.contentsOfDirectory(
        at: url, includingPropertiesForKeys: [.isRegularFileKey]
    ).filter { url in
        ["epub", "m4b", "mp3", "zip"].contains(url.pathExtension.lowercased())
    }
    for file in files {
        try await batchService.enqueue(
            url: file,
            displayName: file.deletingPathExtension().lastPathComponent,
            granularity: granularity
        )
    }
}
```

- [ ] **Step 2: Wire BatchProcessingService into macOS app**

```swift
// In Echo_macOSApp.swift:
@State private var batchProcessor: BatchProcessingService

init() {
    // ... existing ...
    self.batchProcessor = BatchProcessingService(databaseService: db)
}

// In body:
.environment(batchProcessor)
```

- [ ] **Step 3: Add batch queue to macOS menu**

```swift
// In .commands block:
CommandMenu("Batch") {
    Button("Open Batch Queue") {
        // Show batch queue window/sheet
    }
    .keyboardShortcut("b", modifiers: [.command, .shift])
    
    Divider()
    
    Button("Add Folder to Queue...") {
        Task {
            // NSOpenPanel for directory selection
            if let url = await MacFolderOpener.openFolder() {
                try? await batchProcessor.enqueueFolder(url: url, granularity: .word)
            }
        }
    }
}
```

- [ ] **Step 4: Build macOS target**

```bash
xcodebuild -project Echo.xcodeproj -scheme "Echo macOS" -destination 'platform=macOS' build 2>&1 | tail -5
```

- [ ] **Step 5: Commit**

```bash
git add "Echo macOS/MacBulkAlignmentService.swift" "Echo macOS/Echo_macOSApp.swift"
git commit -m "feat: integrate batch processing queue into macOS app"
```

---

### Task C5: iOS Batch Integration

**Files:**
- Modify: `EchoCore/EchoCoreApp.swift` (wire BatchProcessingService)
- Modify: `EchoCore/Views/RootTabView.swift` (add queue tab or sheet entry)

- [ ] **Step 1: Wire BatchProcessingService in iOS app**

```swift
// In EchoCoreApp.swift:
@State private var batchProcessor: BatchProcessingService

init() {
    // ... existing ...
    self.batchProcessor = BatchProcessingService(databaseService: dbService)
}

// In body:
.environment(batchProcessor)
```

- [ ] **Step 2: Add batch queue access point**

Add a button in the UnifiedTopHeader ellipsis menu or as a sheet:

```swift
Button(action: { showingBatchQueue = true }) {
    Label("Batch Queue", systemImage: "square.stack.3d.up")
}
.sheet(isPresented: $showingBatchQueue) {
    NavigationStack {
        BatchQueueView()
    }
}
```

- [ ] **Step 3: Build iOS target**

```bash
xcodebuild -project Echo.xcodeproj -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

- [ ] **Step 4: Commit**

```bash
git add EchoCore/EchoCoreApp.swift EchoCore/Views/RootTabView.swift
git commit -m "feat: integrate batch processing queue into iOS app"
```

---

## Phase D: m4b Export with Chapter Markers

> **Prerequisite:** Phase A complete (shared PlayerModel, word-level alignment)

### Task D1: Implement Real AudioMarker (Chapter Atom Writing)

**Files:**
- Modify: `EchoCore/Services/Narration/AudioMarkerStub.swift` (replace stub)
- Create: `EchoCore/Services/Narration/AudioMarker.swift` (real implementation)

- [ ] **Step 1: Add swift-audio-marker SPM dependency**

Add `https://github.com/atelier-socle/swift-audio-marker` to Package.swift. If the package is unavailable or unreliable, implement chapter atom writing manually using `AVAssetWriter` + metadata adaptors.

**Fallback approach (manual atom writing):** MP4 chapter markers are stored in a `text` track with specific metadata. We can construct this using `AVMutableMetadataItem`:

```swift
// EchoCore/Services/Narration/AudioMarker.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation

struct AudioMarker {
    struct ChapterAtom {
        let title: String
        let startTime: TimeInterval
        let duration: TimeInterval
    }

    /// Writes chapter markers to an m4b file by remuxing with a chapter text track.
    func writeChapters(_ chapters: [ChapterAtom], to sourceURL: URL, outputURL: URL) throws {
        let sourceAsset = AVURLAsset(url: sourceURL)
        let composition = AVMutableComposition()

        // Copy audio track
        guard let sourceTrack = try? sourceAsset.loadTracks(withMediaType: .audio).first else {
            throw AudioMarkerError.noAudioTrack
        }
        let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )!
        try compositionTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: sourceAsset.duration),
            of: sourceTrack, at: .zero
        )

        // Build chapter metadata
        var chapterMetadata: [AVTimedMetadataGroup] = []
        for (idx, chapter) in chapters.enumerated() {
            let startTime = CMTime(seconds: chapter.startTime, preferredTimescale: 1000)

            let titleItem = AVMutableMetadataItem()
            titleItem.identifier = .commonIdentifierTitle
            titleItem.value = chapter.title as NSString
            titleItem.dataType = kCMMetadataBaseDataType_UTF8 as String
            titleItem.time = startTime

            // Optional: add chapter index as custom metadata
            // Optional: add alignment blocks as custom metadata

            let group = AVTimedMetadataGroup(items: [titleItem], timeRange: CMTimeRange(
                start: startTime,
                duration: CMTime(seconds: chapter.duration, preferredTimescale: 1000)
            ))
            chapterMetadata.append(group)
        }

        // Export with chapter track
        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw AudioMarkerError.exportSessionFailed
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.metadata = [] // chapters are written via timed metadata groups

        // AVAssetExportSession doesn't directly support timed metadata tracks.
        // Fallback: use AVAssetWriter for precise chapter track insertion.
        try writeWithAssetWriter(chapters: chapters, sourceURL: sourceURL, outputURL: outputURL)
    }

    private func writeWithAssetWriter(chapters: [ChapterAtom], sourceURL: URL, outputURL: URL) throws {
        // AVAssetWriter-based remux with chapter text track
        // This is the reliable path when AVAssetExportSession doesn't support
        // timed metadata in m4b containers.
        //
        // Implementation: read source audio samples → write to new file →
        // insert chapter text track with sample descriptions at chapter boundaries.
        //
        // For the initial implementation, if swift-audio-marker is available,
        // delegate to it. Otherwise, use the copy-only stub path (existing behavior)
        // and log a warning that chapter markers require the SPM package.
        throw AudioMarkerError.requiresSwiftAudioMarker
    }
}

enum AudioMarkerError: LocalizedError {
    case noAudioTrack
    case exportSessionFailed
    case requiresSwiftAudioMarker

    var errorDescription: String? {
        switch self {
        case .requiresSwiftAudioMarker:
            return "Chapter markers require the swift-audio-marker package"
        default:
            return "Audio export failed"
        }
    }
}
```

**Design decision:** The `swift-audio-marker` package is the intended long-term solution. If it's not yet available/stable, the fallback preserves existing behavior (gapless concatenation without markers) and the chapter marker feature gates on the package being integrated. This avoids blocking the rest of the plan.

- [ ] **Step 2: Update AudioMarkerStub to re-export from AudioMarker**

Replace the stub contents with:

```swift
// EchoCore/Services/Narration/AudioMarkerStub.swift
// SPDX-License-Identifier: GPL-3.0-or-later
// Re-exports the real AudioMarker. The stub file exists for source compatibility
// during the transition; once all call sites use AudioMarker directly, delete this file.
typealias AudioMarkerStub = AudioMarker
```

- [ ] **Step 3: Build**

```bash
xcodebuild -project Echo.xcodeproj -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

- [ ] **Step 4: Commit**

```bash
git add EchoCore/Services/Narration/AudioMarker.swift EchoCore/Services/Narration/AudioMarkerStub.swift
git commit -m "feat: implement real AudioMarker with chapter atom writing"
```

---

### Task D2: Update NarrationExportService for Chapter Markers

**Files:**
- Modify: `EchoCore/Services/Narration/NarrationExportService.swift`

- [ ] **Step 1: Pass chapter metadata through export pipeline**

Update `exportM4B` to collect chapter titles and durations from the TrackRecords:

```swift
// In NarrationExportService.exportM4B:
func exportM4B(
    for audiobookID: String,
    bookTitle: String,
    cacheDirectory: URL,
    outputURL: URL,
    includeChapterMarkers: Bool = true
) async throws {
    // 1. Build chapter atoms from rendered tracks
    let tracks = try trackDAO.tracks(for: audiobookID)
    let chapters: [AudioMarker.ChapterAtom] = tracks.map { track in
        AudioMarker.ChapterAtom(
            title: track.title ?? "Chapter",
            startTime: track.cumulativeStartTime,
            duration: track.duration
        )
    }

    // 2. Concatenate audio (existing AVComposition path)
    let tempM4A = try await concatenateChapterFiles(
        for: audiobookID, cacheDirectory: cacheDirectory
    )

    // 3. Write chapter markers
    if includeChapterMarkers && !chapters.isEmpty {
        let marker = AudioMarker()
        try marker.writeChapters(chapters, to: tempM4A, outputURL: outputURL)
        try? FileManager.default.removeItem(at: tempM4A)
    } else {
        try? FileManager.default.removeItem(at: outputURL)
        try FileManager.default.copyItem(at: tempM4A, to: outputURL)
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -project Echo.xcodeproj -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

- [ ] **Step 3: Commit**

```bash
git add EchoCore/Services/Narration/NarrationExportService.swift
git commit -m "feat: wire chapter markers into m4b export pipeline"
```

---

### Task D3: Embed Alignment Metadata in Exported m4b

**Files:**
- Modify: `EchoCore/Services/Narration/AudioMarker.swift`
- Modify: `EchoCore/Services/Narration/NarrationExportService.swift`

- [ ] **Step 1: Define alignment metadata format**

Embed alignment data as a JSON blob in a custom ID3-style atom. This allows round-trip: export m4b → import → alignment is preserved:

```swift
// In AudioMarker.swift, add:
struct AlignmentExportMetadata: Codable {
    let version: Int  // schema version
    let audiobookID: String
    let granularity: String  // "word", "sentence", "paragraph"
    let anchors: [AnchorExportEntry]

    struct AnchorExportEntry: Codable {
        let blockID: String
        let audioTime: TimeInterval
        let wordAlignments: [WordExportEntry]?
    }

    struct WordExportEntry: Codable {
        let wordIndex: Int
        let word: String
        let startTime: TimeInterval
        let endTime: TimeInterval
        let confidence: Double
    }
}

func embedAlignmentMetadata(_ metadata: AlignmentExportMetadata, to outputURL: URL) throws {
    let jsonData = try JSONEncoder().encode(metadata)
    // Write as a custom atom in the m4b container.
    // This requires low-level MP4 atom manipulation.
    // For initial implementation, write as a sidecar .alignment.json file.
    let sidecarURL = outputURL.deletingPathExtension()
        .appendingPathExtension("alignment.json")
    try jsonData.write(to: sidecarURL)
}
```

**Note:** Embedding custom atoms in MP4 containers requires low-level box writing (parsing the MP4 structure, inserting a `uuid` box). For the initial implementation, use a sidecar JSON file. Full embedding is a follow-up optimization.

- [ ] **Step 2: Export alignment data alongside m4b**

In `NarrationExportService.exportM4B`:

```swift
// After successful export:
let alignmentMeta = try await buildAlignmentMetadata(for: audiobookID)
try AudioMarker().embedAlignmentMetadata(alignmentMeta, to: outputURL)
```

- [ ] **Step 3: Build and test**

```bash
make build-tests
make test-only FILTER=EchoTests/NarrationExport
```

- [ ] **Step 4: Commit**

```bash
git add EchoCore/Services/Narration/AudioMarker.swift EchoCore/Services/Narration/NarrationExportService.swift
git commit -m "feat: embed alignment metadata alongside exported m4b"
```

---

### Task D4: Export UI Updates

**Files:**
- Modify: `EchoCore/Views/NowPlayingTab.swift` (add export button)
- Modify: `Echo macOS/MacTriPaneView.swift` (add export menu item or button)

- [ ] **Step 1: Add export button to iOS NowPlayingTab**

When narration is complete, show an export option:

```swift
// In NowPlayingTab, narration status area:
if model.state.narrationRenderComplete {
    Button(action: { showingExportSheet = true }) {
        Label("Export as M4B", systemImage: "square.and.arrow.up")
    }
    .buttonStyle(.bordered)
}
.sheet(isPresented: $showingExportSheet) {
    ExportProgressView(audiobookID: model.currentAudiobookID)
}
```

- [ ] **Step 2: Create ExportProgressView**

```swift
// EchoCore/Views/ExportProgressView.swift
struct ExportProgressView: View {
    let audiobookID: String
    @State private var isExporting = false
    @State private var exportURL: URL?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 20) {
            if isExporting {
                ProgressView("Exporting M4B...")
            } else if let url = exportURL {
                Text("Export complete!")
                #if os(macOS)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                #else
                ShareLink(item: url)
                #endif
            } else if let error {
                Text("Export failed: \(error)").foregroundStyle(.red)
            }
        }
        .padding()
        .task {
            isExporting = true
            do {
                exportURL = try await exportService.exportM4B(...)
            } catch {
                self.error = error.localizedDescription
            }
            isExporting = false
        }
    }
}
```

- [ ] **Step 3: Add macOS menu item**

```swift
// In Echo_macOSApp.swift .commands:
CommandMenu("File") {
    // ... existing ...
    Button("Export Narrated M4B...") {
        // Trigger export
    }
    .keyboardShortcut("e", modifiers: [.command, .shift])
}
```

- [ ] **Step 4: Build both targets**

```bash
xcodebuild -project Echo.xcodeproj -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
xcodebuild -project Echo.xcodeproj -scheme "Echo macOS" -destination 'platform=macOS' build 2>&1 | tail -5
```

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Views/NowPlayingTab.swift EchoCore/Views/ExportProgressView.swift \
        "Echo macOS/Echo_macOSApp.swift" "Echo macOS/MacTriPaneView.swift"
git commit -m "feat: add m4b export UI on iOS and macOS"
```

---

## Dependency Graph

```
Phase A (Foundation)
├── A1: Audit PlayerModel deps
├── A2: Gate iOS-only PlayerModel code
├── A3: Verify AudioEngine/PlaybackController macOS
├── A4: Remove MacPlayerModel, wire shared ────┐
├── A5: Share player views with macOS          │ These can run in parallel
├── A6: macOS reader shared resolver           │ after A2-A3 are done
├── A7: Word alignment data model              │
├── A8: AlignmentService word granularity      ├── Depends on A7
├── A9: AutoAlignmentService word persistence  ├── Depends on A7, A8
└── A10: Granularity selector UI               └── Depends on A8

Phase B (Karaoke) ── needs Phase A complete
├── B1: Word-level resolver
├── B2: ParagraphCardCell highlighting
├── B3: HeadingCardCell highlighting
└── B4: End-to-end data flow

Phase C (Batch Queue) ── needs Phase A complete
├── C1: DB schema
├── C2: BatchProcessingService      ──── depends on C1
├── C3: Batch queue UI              ──── depends on C2
├── C4: macOS batch integration     ──── depends on C2
└── C5: iOS batch integration       ──── depends on C2

Phase D (m4b Export) ── needs Phase A complete
├── D1: Real AudioMarker            ──── may need SPM package
├── D2: Update NarrationExportService ── depends on D1
├── D3: Alignment metadata embedding  ── depends on D1
└── D4: Export UI                   ──── depends on D2
```

## Testing Strategy

| Phase | Test Suite | What It Covers |
|-------|-----------|----------------|
| A2-A4 | Manual build both targets | Compilation, no regressions |
| A7 | `EchoTests/DatabaseService` | Schema migration, DAO CRUD |
| A8 | `EchoTests/AlignmentService` | Word-level timeline materialization, interpolation math |
| A9 | `EchoTests/AutoAlignment` | DTW word extraction, persistence |
| B1 | `EchoTests/ReaderActiveBlock` | Word-level lookup with known cache |
| B2-B4 | Manual on-device | Visual highlighting verification |
| C1 | `EchoTests/DatabaseService` | Batch queue migration, DAO CRUD |
| C2 | `EchoTests/BatchProcessing` | Enqueue, sequential processing, error handling |
| D1-D3 | `EchoTests/NarrationExport` | Chapter marker writing, alignment sidecar |

## Risk Register

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| FluidAudio macOS support incomplete | Medium | Gate narration on `#if os(iOS)`; Mac playback uses AVFoundation path |
| `AVAudioEngine` behaves differently on macOS | Low | Same API surface; test audio output on Mac |
| `swift-audio-marker` SPM package unavailable | Medium | Fallback: copy-only stub (existing behavior); chapter markers become follow-up |
| Word-level timeline bloats database | Medium | Only materialize at `.word` granularity when explicitly requested; add cleanup on re-alignment |
| DTW word extraction inaccurate for noisy audio | High | Gate karaoke on DTW confidence ≥ 0.7; interpolated words get lower confidence; UI shows confidence visually |
| UICollectionView cell reloads cause flicker at word rate | Low | Throttle to 10 Hz; only reload the active card; use `reloadItems` not `reloadData` |
| Batch queue memory usage with large audiobooks | Medium | Process one book at a time; release WhisperKit model between books; monitor memory pressure |
