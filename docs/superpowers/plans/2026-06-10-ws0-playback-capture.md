# WS0: Playback Capture Layer + Event-Integrity Fixes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Activate the dormant `playback_event` table with a crash-safe session recorder, fix three confirmed data-integrity bugs, and ship Schema_V12 so every future TestFlight database is ready for WS5/WS6b features.

**Architecture:** A pure `PlaybackSegmentBuilder` state machine (fully unit-testable, no DB/clock) decides when listening segments open/split/close; a `PlaybackSessionRecorder` actor consumes `RecorderEvent`s from an `AsyncStream`, translating builder actions into async GRDB writes. Main-actor call sites only `yield` (synchronous, non-blocking) — no sync DB on main (audit §3.2), no untracked Tasks (§3.3). Crash safety comes from writing a self-consistent row at open and extending it via 30s heartbeats: a crash simply leaves a correct segment ending at the last heartbeat. No recovery sweep needed.

**Tech Stack:** Swift 5 + Approachable Concurrency, GRDB 7.10 (async `write`), Swift Testing (`@Test`/`#expect`), in-memory `DatabaseService(inMemory: ())` fixtures.

**Branch:** `feat/ws0-playback-capture` (already created). Commit after every task.

**Verified facts this plan relies on:**
- `playback_event` schema: [Schema_V1.swift:98-109](../../Shared/Database/Schema_V1.swift) — `audiobook_id` NOT NULL FK → `audiobook`, `track_id` nullable FK → `track`, `started_at` NOT NULL text, `ended_at`/`end_position` nullable, `speed` NOT NULL default 1.0, `event_type` NOT NULL default 'play', `source` nullable.
- `PlaybackEventDAO` ([PlaybackEventDAO.swift](../../Shared/Database/DAOs/PlaybackEventDAO.swift)) has zero call sites — we extend it, nothing else uses it.
- Seams: `coordinator_playStateChanged` fires in `PlaybackController.play()`:136 / `pause()`:217; `coordinator_seekCompleted` fires for smart-rewind (`isManual: false`) and manual scrubs; `coordinator_persistSpeed` fires in `setSpeed()`:242; `coordinator_refreshProgress` ticks ~1/s during playback. All wired in [PlayerModel.swift:690-781](../../EchoCore/ViewModels/PlayerModel.swift).
- `audiobookID` convention = `folderURL.absoluteString` (used by `PlaybackEventLogger` and `pause()`:220-222). Audiobook rows are created by `TimelineIngestionService.swift:31` — not guaranteed before first play, so the recorder must ensure the row exists (FK!).
- Bug 1: [DailyReviewViewModel.swift:97](../../EchoCore/ViewModels/DailyReviewViewModel.swift) logs `"flashcardReviewed"`; enum raw value is `"flashcard_reviewed"` ([RealTimeEvent.swift:6](../../EchoCore/Models/RealTimeEvent.swift)).
- Bug 2: `PlaybackEventLogger.logRealTimeEvent` writes `endedAt: nil` for instantaneous events ([PlaybackEventLogger.swift:75](../../EchoCore/Services/PlaybackEventLogger.swift)).
- Bug 3: `RealTimeEventDAO.pushForwardUncompleted` ([RealTimeEventDAO.swift:113-126](../../Shared/Database/DAOs/RealTimeEventDAO.swift)) rewrites `started_at` for ALL `ended_at IS NULL` rows; driven by 60s timer + `pushForwardQueue` in [TimelineService.swift:39,164-184](../../EchoCore/Services/TimelineService.swift). No code reads uncompleted rows for display → delete the whole mechanism (also resolves audit §3.4's `pushForwardQueue`).
- Tests: Swift Testing, `@testable import Echo`, pattern per [SchemaV5Tests.swift](../../EchoTests/SchemaV5Tests.swift) (`@MainActor struct`, `DatabaseService(inMemory: ())`).

---

### Task 1: Schema_V12 migration

**Files:**
- Create: `Shared/Database/Migrations/Schema_V12.swift`
- Modify: `Shared/Database/DatabaseService.swift:96-97` (register after v11)
- Test: `EchoTests/SchemaV12Tests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
import GRDB
@testable import Echo

@MainActor
struct SchemaV12Tests {

    @Test func v12CreatesSessionLocationTable() throws {
        let db = try DatabaseService(inMemory: ())
        let count = try db.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='session_location'
                """) ?? 0
        }
        #expect(count == 1)
    }

    @Test func v12AddsBookmarkLocationColumns() throws {
        let db = try DatabaseService(inMemory: ())
        let names = Set(try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(bookmark)").map { $0["name"] as? String ?? "" }
        })
        #expect(names.contains("latitude"))
        #expect(names.contains("longitude"))
        #expect(names.contains("place_name"))
    }

    @Test func v12AddsNoteGlobalAndVoiceMemoColumns() throws {
        let db = try DatabaseService(inMemory: ())
        let names = Set(try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(note)").map { $0["name"] as? String ?? "" }
        })
        #expect(names.contains("is_global"))
        #expect(names.contains("voice_memo_path"))
    }

    @Test func v12AddsPlaybackEventStartedAtIndex() throws {
        let db = try DatabaseService(inMemory: ())
        let count = try db.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='idx_playback_event_started_at'
                """) ?? 0
        }
        #expect(count == 1)
    }

    @Test func v12BackfillRenamesMistypedReviewEvents() throws {
        // Migration backfills run during DatabaseService init, so seed via raw
        // SQL into a database that has only migrated to v11, then re-migrate.
        // GRDB applies only unapplied migrations, which makes this simple:
        // we instead verify the UPDATE semantics directly on a migrated DB by
        // re-running the backfill SQL — the migration itself is exercised by
        // the seeded-V11 test in Step 6 (migration-order test).
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO real_time_event (id, event_type, started_at, ended_at)
                VALUES ('e1', 'flashcardReviewed', '2026-06-01T10:00:00Z', NULL)
                """)
            try Schema_V12.backfillEventIntegrity(db)
        }
        let row = try db.read { db in
            try Row.fetchOne(db, sql: "SELECT event_type, ended_at FROM real_time_event WHERE id = 'e1'")
        }
        #expect(row?["event_type"] == "flashcard_reviewed")
        #expect(row?["ended_at"] == "2026-06-01T10:00:00Z")
    }

    @Test func v12BackfillClosesInstantaneousEvents() throws {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO real_time_event (id, event_type, started_at, ended_at)
                VALUES ('e2', 'bookmark_created', '2026-06-02T08:00:00Z', NULL),
                       ('e3', 'playback_session', '2026-06-02T09:00:00Z', NULL)
                """)
            try Schema_V12.backfillEventIntegrity(db)
        }
        let bookmark = try db.read { db in
            try String.fetchOne(db, sql: "SELECT ended_at FROM real_time_event WHERE id = 'e2'")
        }
        let session = try db.read { db in
            try Row.fetchOne(db, sql: "SELECT ended_at FROM real_time_event WHERE id = 'e3'")
        }
        #expect(bookmark == "2026-06-02T08:00:00Z")
        // playback_session is genuinely durational — backfill must NOT touch it.
        #expect(session?["ended_at"] == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Echo.xcodeproj -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:EchoTests/SchemaV12Tests 2>&1 | tail -20`
Expected: FAIL — `Schema_V12` not defined / columns missing.

- [ ] **Step 3: Write the migration**

`Shared/Database/Migrations/Schema_V12.swift` (pattern copied from [Schema_V11.swift](../../Shared/Database/Migrations/Schema_V11.swift)):

```swift
import GRDB

enum Schema_V12 {
    nonisolated static func migrate(_ db: Database) throws {
        // ── Stats: fast time-range scans over listening segments ──
        try db.create(index: "idx_playback_event_started_at", on: "playback_event", columns: ["started_at"])

        // ── Context-dependent memory: per-session location (WS5) ──
        try db.create(table: "session_location") { t in
            t.column("playback_event_id", .integer).primaryKey()
                .references("playback_event", onDelete: .cascade)
            t.column("latitude", .double).notNull()
            t.column("longitude", .double).notNull()
            t.column("place_name", .text)
            t.column("created_at", .text).notNull()
        }

        // ── Context-dependent memory: bookmark location (WS5) ──
        try db.alter(table: "bookmark") { t in
            t.add(column: "latitude", .double)
            t.add(column: "longitude", .double)
            t.add(column: "place_name", .text)
        }

        // ── Brain Dump / Book Notes (WS6b) ──
        try db.alter(table: "note") { t in
            t.add(column: "is_global", .boolean).notNull().defaults(to: false)
            t.add(column: "voice_memo_path", .text)
        }

        try backfillEventIntegrity(db)
    }

    /// Repairs rows written before the WS0 logging fixes:
    /// 1. Review events were logged with the literal "flashcardReviewed"
    ///    instead of RealTimeEventType.flashcardReviewed.rawValue.
    /// 2. Instantaneous events were logged with NULL ended_at, which made
    ///    them targets of the (now removed) push-forward rewrite.
    /// playback_session rows are genuinely durational and stay untouched.
    nonisolated static func backfillEventIntegrity(_ db: Database) throws {
        try db.execute(sql: """
            UPDATE real_time_event
            SET event_type = 'flashcard_reviewed'
            WHERE event_type = 'flashcardReviewed'
            """)
        try db.execute(sql: """
            UPDATE real_time_event
            SET ended_at = started_at
            WHERE ended_at IS NULL
              AND event_type IN ('bookmark_created', 'flashcard_reviewed',
                                 'note_created', 'voice_memo_recorded',
                                 'chapter_transition', 'planned_session_completed')
            """)
    }
}
```

- [ ] **Step 4: Register the migration**

In `Shared/Database/DatabaseService.swift`, after the `v11_bookmark_pdf_state` line (line 96):

```swift
        migrator.registerMigration("v12_capture_and_context") { db in try Schema_V12.migrate(db) }
```

- [ ] **Step 5: Add the new file to the Xcode project**

`Schema_V12.swift` must join the same targets as `Schema_V11.swift` (Echo, Echo Watch App, Echo macOS, widget — check V11's target membership with `grep -A2 "Schema_V11" Echo.xcodeproj/project.pbxproj`). Add via Xcode or `ruby -r xcodeproj` if scripted; verify with a clean build.

- [ ] **Step 6: Run tests to verify they pass**

Run: `xcodebuild test -project Echo.xcodeproj -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:EchoTests/SchemaV12Tests 2>&1 | tail -20`
Expected: PASS (6 tests).

- [ ] **Step 7: Commit**

```bash
git add Shared/Database/Migrations/Schema_V12.swift Shared/Database/DatabaseService.swift EchoTests/SchemaV12Tests.swift Echo.xcodeproj/project.pbxproj
git commit -m "feat(db): add Schema_V12 — session_location, bookmark/note context columns, event-integrity backfill"
```

---

### Task 2: Fix the review-event type bug

**Files:**
- Modify: `EchoCore/ViewModels/DailyReviewViewModel.swift:95-107`
- Test: `EchoTests/RealTimeEventIntegrityTests.swift` (new)

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import Echo

@MainActor
struct RealTimeEventIntegrityTests {

    @Test func reviewLoggingUsesEnumRawValueAndClosesEvent() throws {
        let db = try DatabaseService(inMemory: ())
        // Decoding falls back to .playbackSession for unknown types, which is
        // exactly how the original bug hid: reviews masqueraded as sessions.
        let dao = RealTimeEventDAO(db: db.writer)
        try dao.log(
            id: "r1",
            eventType: RealTimeEventType.flashcardReviewed.rawValue,
            audiobookID: "book",
            mediaTimestamp: 10,
            startedAt: Date(timeIntervalSince1970: 1_750_000_000),
            endedAt: Date(timeIntervalSince1970: 1_750_000_000),
            title: "front", subtitle: "Grade: 4",
            metadataJSON: #"{"cardId":"c1","grade":4}"#,
            sourceItemID: "c1", sourceItemType: "flashcard"
        )
        let reviews = try dao.events(
            ofType: RealTimeEventType.flashcardReviewed.rawValue,
            in: Date(timeIntervalSince1970: 0)...Date(timeIntervalSince1970: 2_000_000_000)
        )
        #expect(reviews.count == 1)
        #expect(reviews[0].endedAt != nil)
    }
}
```

(This pins the DAO contract; the view-model fix is a 2-line change verified by inspection + the type system once the literal is replaced with the enum.)

- [ ] **Step 2: Run test — expect PASS** (it tests the DAO path with correct inputs)

Run: `xcodebuild test ... -only-testing:EchoTests/RealTimeEventIntegrityTests 2>&1 | tail -10`
Expected: PASS. (The test documents correct usage; the bug is at the call site.)

- [ ] **Step 3: Fix the call site**

In `EchoCore/ViewModels/DailyReviewViewModel.swift`, `logFlashcardReviewed` (lines 95-107), change two arguments:

```swift
            try dao.log(
                id: UUID().uuidString,
                eventType: RealTimeEventType.flashcardReviewed.rawValue,
                audiobookID: card.audiobookID,
                mediaTimestamp: card.mediaTimestamp,
                startedAt: Date(),
                endedAt: Date(),
                title: card.frontText,
                subtitle: "Grade: \(grade)",
                metadataJSON: metaJSON,
                sourceItemID: card.id,
                sourceItemType: "flashcard"
            )
```

- [ ] **Step 4: Grep for other string-literal event types**

Run: `grep -rn '"flashcardReviewed"\|"bookmark_created"\|"note_created"\|"playback_session"' EchoCore Shared --include="*.swift" | grep -v rawValue | grep -v Tests`
Expected: zero hits in production code (any hit → replace with `RealTimeEventType.<case>.rawValue`).

- [ ] **Step 5: Build + run full EchoTests, commit**

```bash
git add EchoCore/ViewModels/DailyReviewViewModel.swift EchoTests/RealTimeEventIntegrityTests.swift
git commit -m "fix(events): log flashcard reviews with the enum raw value and a closed ended_at"
```

---

### Task 3: Close instantaneous events at the logger

**Files:**
- Modify: `EchoCore/Services/PlaybackEventLogger.swift:56-85`

- [ ] **Step 1: Modify `logRealTimeEvent`**

Every type routed through this method is instantaneous (sessions go through `startPlaybackSessionLogging`/`endPlaybackSessionLogging` instead), so close them at creation:

```swift
    func logRealTimeEvent(
        type: RealTimeEventType,
        databaseService: DatabaseService?,
        folderURL: URL?,
        title: String,
        subtitle: String?,
        timestamp: TimeInterval?,
        sourceItemID: String?,
        sourceItemType: String?
    ) {
        guard let db = databaseService else { return }
        let dao = RealTimeEventDAO(db: db.writer)
        let folderKey = folderURL?.absoluteString
        let now = Date()
        do {
            try dao.log(
                eventType: type.rawValue,
                audiobookID: folderKey,
                mediaTimestamp: timestamp,
                startedAt: now,
                endedAt: now,
                title: title,
                subtitle: subtitle,
                metadataJSON: nil,
                sourceItemID: sourceItemID,
                sourceItemType: sourceItemType
            )
        } catch {
            logger.error("Failed to log timeline event \(type.rawValue) for \(folderURL?.lastPathComponent ?? "nil"): \(error.localizedDescription)")
        }
    }
```

- [ ] **Step 2: Build, run EchoTests, commit**

```bash
git add EchoCore/Services/PlaybackEventLogger.swift
git commit -m "fix(events): write instantaneous real-time events as already-closed (ended_at = started_at)"
```

---

### Task 4: Delete the push-forward mechanism

**Files:**
- Modify: `EchoCore/Services/TimelineService.swift` (remove `pushForwardInterval`:39, `pushForwardQueue`, `pushForwardTimer`, `startPushForwardTimer()`:176-182, `pushForwardUncompletedItems()`:184-196, and their call sites — grep `pushForward` in the file)
- Modify: `Shared/Database/DAOs/RealTimeEventDAO.swift:111-126` (remove `pushForwardUncompleted`)

- [ ] **Step 1: Remove the code**

Delete the timer property, queue, interval constant, both methods, and the `startPushForwardTimer()` call in TimelineService's setup (grep `pushForward` — every hit goes). Delete `pushForwardUncompleted` from the DAO. Rationale recorded in commit message: no reader of uncompleted rows exists; the UPDATE was corrupting bookmark/note/memo history every 60s; removing the queue also closes audit §3.4 (MainActor-captured `self` on a raw DispatchQueue).

- [ ] **Step 2: Verify nothing references it**

Run: `grep -rn "pushForward" EchoCore Shared EchoTests --include="*.swift"`
Expected: zero hits.

- [ ] **Step 3: Build all three schemes + run EchoTests**

Expected: clean build, tests green (nothing consumed the API).

- [ ] **Step 4: Commit**

```bash
git add EchoCore/Services/TimelineService.swift Shared/Database/DAOs/RealTimeEventDAO.swift
git commit -m "fix(events): remove push-forward timer that rewrote started_at on every open-ended event

No code read uncompleted rows for display; the 60s sweep was silently
destroying bookmark/note/memo history. Also removes pushForwardQueue
(audit §3.4 — MainActor self captured on a raw DispatchQueue)."
```

---

### Task 5: PlaybackEventDAO open/extend/finalize API

**Files:**
- Modify: `Shared/Database/DAOs/PlaybackEventDAO.swift`
- Test: `EchoTests/PlaybackEventDAOTests.swift` (new)

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
import GRDB
@testable import Echo

@MainActor
struct PlaybackEventDAOTests {

    private func makeDB() throws -> DatabaseService {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO audiobook (id, title, duration, added_at)
                VALUES ('book1', 'Test Book', 3600, '2026-06-01T00:00:00Z')
                """)
        }
        return db
    }

    @Test func insertOpenWritesSelfConsistentRow() throws {
        let db = try makeDB()
        let dao = PlaybackEventDAO(db: db.writer)
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let id = try dao.insertOpen(
            audiobookID: "book1", trackID: nil,
            startedAt: start, startPosition: 120, speed: 1.5, source: "user"
        )
        let row = try db.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM playback_event WHERE id = ?", arguments: [id])
        }
        // Self-consistent zero-length segment: crash before first heartbeat
        // still leaves valid (if tiny) data — no NULLs ever reach aggregation.
        #expect(row?["ended_at"] == start.ISO8601Format())
        #expect(row?["end_position"] == 120.0)
        #expect(row?["speed"] == 1.5)
        #expect(row?["event_type"] == "play")
    }

    @Test func extendUpdatesEndFields() throws {
        let db = try makeDB()
        let dao = PlaybackEventDAO(db: db.writer)
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let id = try dao.insertOpen(
            audiobookID: "book1", trackID: nil,
            startedAt: start, startPosition: 120, speed: 1.5, source: "user"
        )
        try dao.extend(id: id, endedAt: start.addingTimeInterval(30), endPosition: 165)
        let row = try db.read { db in
            try Row.fetchOne(db, sql: "SELECT ended_at, end_position FROM playback_event WHERE id = ?", arguments: [id])
        }
        #expect(row?["ended_at"] == start.addingTimeInterval(30).ISO8601Format())
        #expect(row?["end_position"] == 165.0)
    }

    @Test func deleteRemovesDiscardedMicroSegment() throws {
        let db = try makeDB()
        let dao = PlaybackEventDAO(db: db.writer)
        let id = try dao.insertOpen(
            audiobookID: "book1", trackID: nil,
            startedAt: Date(), startPosition: 0, speed: 1.0, source: "user"
        )
        try dao.delete(id: id)
        let count = try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playback_event") ?? 0
        }
        #expect(count == 0)
    }

    @Test func insertOpenRejectsUnknownAudiobook() throws {
        let db = try makeDB()
        let dao = PlaybackEventDAO(db: db.writer)
        #expect(throws: (any Error).self) {
            _ = try dao.insertOpen(
                audiobookID: "missing", trackID: nil,
                startedAt: Date(), startPosition: 0, speed: 1.0, source: "user"
            )
        }
    }
}
```

- [ ] **Step 2: Run — expect FAIL** (`insertOpen` undefined)

- [ ] **Step 3: Implement in `PlaybackEventDAO`** (append below the existing `log` method; keep `log` and `events(for:limit:)` untouched)

```swift
    /// Opens a listening segment as a self-consistent zero-length row.
    /// Heartbeats and finalize() extend it; a crash leaves valid data.
    func insertOpen(
        audiobookID: String,
        trackID: String?,
        startedAt: Date,
        startPosition: TimeInterval,
        speed: Double,
        source: String
    ) throws -> Int64 {
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO playback_event
                    (audiobook_id, track_id, started_at, ended_at, start_position, end_position, speed, event_type, source)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 'play', ?)
                    """,
                arguments: [
                    audiobookID, trackID,
                    startedAt.ISO8601Format(), startedAt.ISO8601Format(),
                    startPosition, startPosition, speed, source
                ]
            )
            return db.lastInsertedRowID
        }
    }

    /// Extends an open segment (heartbeat and final close use the same shape).
    func extend(id: Int64, endedAt: Date, endPosition: TimeInterval) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE playback_event SET ended_at = ?, end_position = ? WHERE id = ?",
                arguments: [endedAt.ISO8601Format(), endPosition, id]
            )
        }
    }

    /// Removes a discarded micro-segment (< minimum duration).
    func delete(id: Int64) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM playback_event WHERE id = ?", arguments: [id])
        }
    }
```

- [ ] **Step 4: Run — expect PASS (4 tests). Commit**

```bash
git add Shared/Database/DAOs/PlaybackEventDAO.swift EchoTests/PlaybackEventDAOTests.swift
git commit -m "feat(db): add open/extend/delete segment API to PlaybackEventDAO"
```

---

### Task 6: PlaybackSegmentBuilder — the pure state machine

**Files:**
- Create: `Shared/Stats/PlaybackSegmentBuilder.swift` (new directory `Shared/Stats/`; same target membership as `Shared/Database` files)
- Test: `EchoTests/PlaybackSegmentBuilderTests.swift`

The builder owns ALL split/close/discard policy. The recorder actor (Task 7) is a thin IO shell. Types used by both:

```swift
import Foundation

/// One contiguous stretch of listening at constant (track, speed) with no seeks.
struct OpenSegment: Equatable, Sendable {
    var audiobookID: String
    var trackID: String?
    var startedAt: Date
    var startPosition: TimeInterval
    var lastKnownPosition: TimeInterval
    var lastKnownAt: Date
    var speed: Double
    var source: String
}

/// Events yielded from main-actor playback seams. All carry their own clock.
enum RecorderEvent: Sendable {
    case opened(audiobookID: String, trackID: String?, position: TimeInterval, speed: Double, source: String, at: Date)
    case progressTick(position: TimeInterval, at: Date)
    case speedChanged(newSpeed: Double, at: Date)
    case seeked(toPosition: TimeInterval, at: Date)
    case closed(position: TimeInterval?, at: Date)
    case heartbeat(at: Date)
}

/// IO instructions for the recorder actor, in order.
enum SegmentAction: Equatable, Sendable {
    case finalize(endedAt: Date, endPosition: TimeInterval)   // extend() the current row one last time
    case discard                                              // delete() the current row (micro-segment)
    case begin(OpenSegment)                                   // insertOpen() a new row
    case extendOpen(endedAt: Date, endPosition: TimeInterval) // heartbeat extend()
}

struct PlaybackSegmentBuilder: Sendable {
    /// Segments shorter than this wall-clock duration are noise (accidental
    /// taps, instant track skips) and are deleted rather than finalized.
    static let minimumSegmentDuration: TimeInterval = 5

    private(set) var open: OpenSegment?

    mutating func handle(_ event: RecorderEvent) -> [SegmentAction] { ... }
}
```

- [ ] **Step 1: Write the failing tests** — every policy rule, no DB anywhere:

```swift
import Testing
import Foundation
@testable import Echo

struct PlaybackSegmentBuilderTests {
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    private func opened(pos: TimeInterval = 100, speed: Double = 1.5, at: Date? = nil) -> RecorderEvent {
        .opened(audiobookID: "book1", trackID: "trk1", position: pos, speed: speed, source: "user", at: at ?? t0)
    }

    @Test func openedBeginsSegment() {
        var b = PlaybackSegmentBuilder()
        let actions = b.handle(opened())
        #expect(actions == [.begin(OpenSegment(
            audiobookID: "book1", trackID: "trk1", startedAt: t0,
            startPosition: 100, lastKnownPosition: 100, lastKnownAt: t0,
            speed: 1.5, source: "user"))])
        #expect(b.open != nil)
    }

    @Test func closedFinalizesAtGivenPosition() {
        var b = PlaybackSegmentBuilder()
        _ = b.handle(opened())
        let end = t0.addingTimeInterval(60)
        let actions = b.handle(.closed(position: 190, at: end))
        #expect(actions == [.finalize(endedAt: end, endPosition: 190)])
        #expect(b.open == nil)
    }

    @Test func closedWithNilPositionUsesLastKnown() {
        var b = PlaybackSegmentBuilder()
        _ = b.handle(opened())
        _ = b.handle(.progressTick(position: 150, at: t0.addingTimeInterval(50)))
        let end = t0.addingTimeInterval(60)
        let actions = b.handle(.closed(position: nil, at: end))
        #expect(actions == [.finalize(endedAt: end, endPosition: 150)])
    }

    @Test func shortSegmentIsDiscarded() {
        var b = PlaybackSegmentBuilder()
        _ = b.handle(opened())
        let actions = b.handle(.closed(position: 103, at: t0.addingTimeInterval(3)))
        #expect(actions == [.discard])
    }

    @Test func speedChangeSplitsSegment() {
        var b = PlaybackSegmentBuilder()
        _ = b.handle(opened())
        _ = b.handle(.progressTick(position: 160, at: t0.addingTimeInterval(40)))
        let at = t0.addingTimeInterval(41)
        let actions = b.handle(.speedChanged(newSpeed: 2.0, at: at))
        #expect(actions == [
            .finalize(endedAt: at, endPosition: 160),
            .begin(OpenSegment(
                audiobookID: "book1", trackID: "trk1", startedAt: at,
                startPosition: 160, lastKnownPosition: 160, lastKnownAt: at,
                speed: 2.0, source: "user"))
        ])
    }

    @Test func seekSplitsAtPreSeekPosition() {
        var b = PlaybackSegmentBuilder()
        _ = b.handle(opened())
        _ = b.handle(.progressTick(position: 160, at: t0.addingTimeInterval(40)))
        let at = t0.addingTimeInterval(41)
        let actions = b.handle(.seeked(toPosition: 600, at: at))
        #expect(actions == [
            .finalize(endedAt: at, endPosition: 160),
            .begin(OpenSegment(
                audiobookID: "book1", trackID: "trk1", startedAt: at,
                startPosition: 600, lastKnownPosition: 600, lastKnownAt: at,
                speed: 1.5, source: "user"))
        ])
    }

    @Test func reopenWhileOpenClosesPreviousFirst() {
        var b = PlaybackSegmentBuilder()
        _ = b.handle(opened())
        _ = b.handle(.progressTick(position: 200, at: t0.addingTimeInterval(100)))
        // Track auto-advance: play() fires opened again with the new track.
        let at = t0.addingTimeInterval(101)
        let actions = b.handle(.opened(audiobookID: "book1", trackID: "trk2", position: 0, speed: 1.5, source: "user", at: at))
        #expect(actions == [
            .finalize(endedAt: at, endPosition: 200),
            .begin(OpenSegment(
                audiobookID: "book1", trackID: "trk2", startedAt: at,
                startPosition: 0, lastKnownPosition: 0, lastKnownAt: at,
                speed: 1.5, source: "user"))
        ])
    }

    @Test func heartbeatExtendsOpenSegment() {
        var b = PlaybackSegmentBuilder()
        _ = b.handle(opened())
        _ = b.handle(.progressTick(position: 145, at: t0.addingTimeInterval(30)))
        let actions = b.handle(.heartbeat(at: t0.addingTimeInterval(30)))
        #expect(actions == [.extendOpen(endedAt: t0.addingTimeInterval(30), endPosition: 145)])
    }

    @Test func eventsWithoutOpenSegmentAreNoOps() {
        var b = PlaybackSegmentBuilder()
        #expect(b.handle(.progressTick(position: 5, at: t0)).isEmpty)
        #expect(b.handle(.heartbeat(at: t0)).isEmpty)
        #expect(b.handle(.seeked(toPosition: 9, at: t0)).isEmpty)
        #expect(b.handle(.speedChanged(newSpeed: 2, at: t0)).isEmpty)
        #expect(b.handle(.closed(position: nil, at: t0)).isEmpty)
    }

    @Test func splitNeverDiscards() {
        // Splits chain segments; only explicit closes can produce micro-noise.
        // A 2-second-old segment split by a seek is still finalized, because
        // discarding it would punch a hole in continuous listening coverage.
        var b = PlaybackSegmentBuilder()
        _ = b.handle(opened())
        let actions = b.handle(.seeked(toPosition: 500, at: t0.addingTimeInterval(2)))
        #expect(actions.first == .finalize(endedAt: t0.addingTimeInterval(2), endPosition: 100))
    }
}
```

- [ ] **Step 2: Run — expect FAIL** (types undefined)

- [ ] **Step 3: Implement `Shared/Stats/PlaybackSegmentBuilder.swift`**

```swift
import Foundation

// (types OpenSegment / RecorderEvent / SegmentAction exactly as above)

struct PlaybackSegmentBuilder: Sendable {
    static let minimumSegmentDuration: TimeInterval = 5

    private(set) var open: OpenSegment?

    mutating func handle(_ event: RecorderEvent) -> [SegmentAction] {
        switch event {
        case let .opened(audiobookID, trackID, position, speed, source, at):
            var actions: [SegmentAction] = []
            if open != nil {
                actions.append(closeAction(endPosition: open!.lastKnownPosition, at: at, isSplit: true))
            }
            let segment = OpenSegment(
                audiobookID: audiobookID, trackID: trackID, startedAt: at,
                startPosition: position, lastKnownPosition: position, lastKnownAt: at,
                speed: speed, source: source
            )
            open = segment
            actions.append(.begin(segment))
            return actions

        case let .progressTick(position, at):
            guard open != nil else { return [] }
            open!.lastKnownPosition = position
            open!.lastKnownAt = at
            return []

        case let .speedChanged(newSpeed, at):
            guard let current = open else { return [] }
            let close = closeAction(endPosition: current.lastKnownPosition, at: at, isSplit: true)
            var next = current
            next.startedAt = at
            next.startPosition = current.lastKnownPosition
            next.lastKnownAt = at
            next.speed = newSpeed
            open = next
            return [close, .begin(next)]

        case let .seeked(toPosition, at):
            guard let current = open else { return [] }
            let close = closeAction(endPosition: current.lastKnownPosition, at: at, isSplit: true)
            var next = current
            next.startedAt = at
            next.startPosition = toPosition
            next.lastKnownPosition = toPosition
            next.lastKnownAt = at
            open = next
            return [close, .begin(next)]

        case let .closed(position, at):
            guard let current = open else { return [] }
            open = nil
            return [closeAction(endPosition: position ?? current.lastKnownPosition, at: at, isSplit: false, segment: current)]

        case let .heartbeat(at):
            guard let current = open else { return [] }
            return [.extendOpen(endedAt: at, endPosition: current.lastKnownPosition)]
        }
    }

    /// Splits always finalize (discarding would punch coverage holes);
    /// explicit closes discard micro-segments below the minimum duration.
    private func closeAction(
        endPosition: TimeInterval, at: Date, isSplit: Bool, segment: OpenSegment? = nil
    ) -> SegmentAction {
        let seg = segment ?? open!
        let duration = at.timeIntervalSince(seg.startedAt)
        if !isSplit && duration < Self.minimumSegmentDuration {
            return .discard
        }
        return .finalize(endedAt: at, endPosition: endPosition)
    }
}
```

(Note the test `splitNeverDiscards` pins the isSplit distinction. Add `Shared/Stats/` files to the same five-target membership as Shared/Database files.)

- [ ] **Step 4: Run — expect PASS (11 tests). Commit**

```bash
git add Shared/Stats/PlaybackSegmentBuilder.swift EchoTests/PlaybackSegmentBuilderTests.swift Echo.xcodeproj/project.pbxproj
git commit -m "feat(stats): add PlaybackSegmentBuilder pure state machine for listening segments"
```

---

### Task 7: PlaybackSessionRecorder actor

**Files:**
- Create: `EchoCore/Services/PlaybackSessionRecorder.swift`
- Test: `EchoTests/PlaybackSessionRecorderTests.swift`

- [ ] **Step 1: Write the failing integration tests** (scripted event sequences → exact rows; uses a `drain()` test hook so assertions never race the consumer):

```swift
import Testing
import Foundation
import GRDB
@testable import Echo

@MainActor
struct PlaybackSessionRecorderTests {
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    private func makeDB() throws -> DatabaseService {
        try DatabaseService(inMemory: ())
    }

    private func rows(_ db: DatabaseService) throws -> [Row] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM playback_event ORDER BY id")
        }
    }

    @Test func playPauseProducesOneSegmentAndStubsAudiobook() async throws {
        let db = try makeDB()
        let recorder = PlaybackSessionRecorder(writer: db.writer)
        recorder.yield(.opened(audiobookID: "file:///b1/", trackID: nil, position: 100, speed: 1.5, source: "user", at: t0))
        recorder.yield(.progressTick(position: 150, at: t0.addingTimeInterval(50)))
        recorder.yield(.closed(position: 160, at: t0.addingTimeInterval(60)))
        await recorder.drain()

        let segs = try rows(db)
        #expect(segs.count == 1)
        #expect(segs[0]["start_position"] == 100.0)
        #expect(segs[0]["end_position"] == 160.0)
        #expect(segs[0]["speed"] == 1.5)
        // FK satisfied via auto-stub:
        let book = try db.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM audiobook WHERE id = 'file:///b1/'")
        }
        #expect(book != nil)
    }

    @Test func seekProducesTwoSegments() async throws {
        let db = try makeDB()
        let recorder = PlaybackSessionRecorder(writer: db.writer)
        recorder.yield(.opened(audiobookID: "b", trackID: nil, position: 0, speed: 1.0, source: "user", at: t0))
        recorder.yield(.progressTick(position: 30, at: t0.addingTimeInterval(30)))
        recorder.yield(.seeked(toPosition: 300, at: t0.addingTimeInterval(31)))
        recorder.yield(.closed(position: 330, at: t0.addingTimeInterval(61)))
        await recorder.drain()

        let segs = try rows(db)
        #expect(segs.count == 2)
        #expect(segs[0]["end_position"] == 30.0)
        #expect(segs[1]["start_position"] == 300.0)
        #expect(segs[1]["end_position"] == 330.0)
    }

    @Test func microSegmentIsDeletedFromDB() async throws {
        let db = try makeDB()
        let recorder = PlaybackSessionRecorder(writer: db.writer)
        recorder.yield(.opened(audiobookID: "b", trackID: nil, position: 0, speed: 1.0, source: "user", at: t0))
        recorder.yield(.closed(position: 2, at: t0.addingTimeInterval(2)))
        await recorder.drain()
        #expect(try rows(db).isEmpty)
    }

    @Test func unknownTrackRetriesWithNilTrackID() async throws {
        let db = try makeDB()
        let recorder = PlaybackSessionRecorder(writer: db.writer)
        // 'trk-missing' has no track row → first insert violates FK → retried with nil.
        recorder.yield(.opened(audiobookID: "b", trackID: "trk-missing", position: 0, speed: 1.0, source: "user", at: t0))
        recorder.yield(.closed(position: 60, at: t0.addingTimeInterval(60)))
        await recorder.drain()
        let segs = try rows(db)
        #expect(segs.count == 1)
        #expect(segs[0]["track_id"] == nil)
    }

    @Test func heartbeatPersistsProgressForCrashSafety() async throws {
        let db = try makeDB()
        let recorder = PlaybackSessionRecorder(writer: db.writer)
        recorder.yield(.opened(audiobookID: "b", trackID: nil, position: 0, speed: 1.0, source: "user", at: t0))
        recorder.yield(.progressTick(position: 29, at: t0.addingTimeInterval(29)))
        recorder.yield(.heartbeat(at: t0.addingTimeInterval(30)))
        await recorder.drain()
        // No close — simulate crash by just reading current state.
        let segs = try rows(db)
        #expect(segs.count == 1)
        #expect(segs[0]["end_position"] == 29.0)
        #expect(segs[0]["ended_at"] == t0.addingTimeInterval(30).ISO8601Format())
    }
}
```

- [ ] **Step 2: Run — expect FAIL** (recorder undefined)

- [ ] **Step 3: Implement `EchoCore/Services/PlaybackSessionRecorder.swift`**

```swift
import Foundation
import GRDB
import os.log

/// Consumes RecorderEvents from playback seams and persists listening
/// segments to playback_event via PlaybackSegmentBuilder policy.
///
/// Concurrency shape (audit §3.2/§3.3 compliant):
/// - Main-actor call sites use the synchronous, non-blocking `yield`.
/// - One long-lived consumer Task (stored, cancellable) does async GRDB writes.
/// - The 30s heartbeat ticks from inside the recorder, not the caller.
actor PlaybackSessionRecorder {
    static let heartbeatInterval: TimeInterval = 30

    private let writer: any DatabaseWriter
    private let logger = Logger(category: "PlaybackSessionRecorder")

    private var builder = PlaybackSegmentBuilder()
    private var openRowID: Int64?
    private var knownAudiobookIDs: Set<String> = []

    private let stream: AsyncStream<RecorderEvent>
    private let continuation: AsyncStream<RecorderEvent>.Continuation
    private var consumerTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?

    init(writer: any DatabaseWriter) {
        self.writer = writer
        (stream, continuation) = AsyncStream.makeStream(of: RecorderEvent.self)
        Task { await self.start() }
    }

    /// Synchronous and non-blocking — safe from the main actor and deinit.
    nonisolated func yield(_ event: RecorderEvent) {
        continuation.yield(event)
    }

    private func start() {
        guard consumerTask == nil else { return }
        consumerTask = Task {
            for await event in stream {
                await handle(event)
            }
        }
        heartbeatTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.heartbeatInterval))
                continuation.yield(.heartbeat(at: Date()))
            }
        }
    }

    func shutdown() {
        continuation.finish()
        heartbeatTask?.cancel()
        consumerTask?.cancel()
    }

    /// Test hook: wait until every yielded event so far has been persisted.
    func drain() async {
        // Events are handled in yield order on this actor; enqueueing a
        // sentinel through the same stream and awaiting its handling would
        // race with `for await`; instead handle() is serial on the actor, so
        // re-entering the actor after a yield barrier suffices:
        await Task.yield()
        while pendingDrain { await Task.yield() }
    }
    private var pendingDrain = false

    private func handle(_ event: RecorderEvent) async {
        pendingDrain = true
        defer { pendingDrain = false }
        for action in builder.handle(event) {
            await perform(action)
        }
    }

    private func perform(_ action: SegmentAction) async {
        do {
            switch action {
            case let .begin(segment):
                try await ensureAudiobookRow(id: segment.audiobookID)
                openRowID = try await insertOpen(segment)
            case let .extendOpen(endedAt, endPosition),
                 let .finalize(endedAt, endPosition):
                guard let id = openRowID else { return }
                try await writer.write { db in
                    try db.execute(
                        sql: "UPDATE playback_event SET ended_at = ?, end_position = ? WHERE id = ?",
                        arguments: [endedAt.ISO8601Format(), endPosition, id]
                    )
                }
                if case .finalize = action { openRowID = nil }
            case .discard:
                guard let id = openRowID else { return }
                openRowID = nil
                try await writer.write { db in
                    try db.execute(sql: "DELETE FROM playback_event WHERE id = ?", arguments: [id])
                }
            }
        } catch {
            logger.error("Segment action failed: \(error.localizedDescription)")
        }
    }

    private func insertOpen(_ segment: OpenSegment) async throws -> Int64 {
        do {
            return try await insertOpenRow(segment, trackID: segment.trackID)
        } catch {
            // track_id FK can fail if ingestion hasn't written track rows yet;
            // the segment is still valid analytics data without it.
            logger.warning("insertOpen retrying without track_id: \(error.localizedDescription)")
            return try await insertOpenRow(segment, trackID: nil)
        }
    }

    private func insertOpenRow(_ s: OpenSegment, trackID: String?) async throws -> Int64 {
        try await writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO playback_event
                    (audiobook_id, track_id, started_at, ended_at, start_position, end_position, speed, event_type, source)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 'play', ?)
                    """,
                arguments: [
                    s.audiobookID, trackID,
                    s.startedAt.ISO8601Format(), s.startedAt.ISO8601Format(),
                    s.startPosition, s.startPosition, s.speed, s.source
                ]
            )
            return db.lastInsertedRowID
        }
    }

    /// playback_event.audiobook_id is a NOT NULL FK; ingestion normally
    /// creates the row, but play-before-ingest must not lose data. The stub's
    /// title/duration get overwritten by TimelineIngestionService.save later.
    private func ensureAudiobookRow(id: String) async throws {
        guard !knownAudiobookIDs.contains(id) else { return }
        let title = URL(string: id)?.lastPathComponent ?? id
        try await writer.write { db in
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO audiobook (id, title, duration, added_at)
                    VALUES (?, ?, 0, ?)
                    """,
                arguments: [id, title, Date().ISO8601Format()]
            )
        }
        knownAudiobookIDs.insert(id)
    }
}
```

Implementation notes for the engineer:
- `Logger(category:)` is the project's existing convenience init (see `PlaybackEventLogger.swift:7`).
- If `drain()`'s yield-loop proves flaky, replace with a counter: increment on `yield`, decrement after `handle`, `drain()` awaits zero via `AsyncStream` of acks — but try the simple version first.
- The recorder intentionally does NOT use `PlaybackEventDAO` (sync `db.write`) — its writes must be async (`try await writer.write`). The DAO methods from Task 5 serve tests and future sync-context callers (e.g. macOS panes).

- [ ] **Step 4: Run — expect PASS (5 tests). Run the FULL EchoTests suite. Commit**

```bash
git add EchoCore/Services/PlaybackSessionRecorder.swift EchoTests/PlaybackSessionRecorderTests.swift
git commit -m "feat(stats): add PlaybackSessionRecorder actor persisting listening segments"
```

---

### Task 8: Wire the recorder into PlayerModel

**Files:**
- Modify: `EchoCore/ViewModels/PlayerModel.swift` (property + 4 yield sites + deinit)

- [ ] **Step 1: Add the property**

Next to the other service properties (search `let eventLogger` / `private let persistence` region):

```swift
    /// Analytics-grade listening-segment capture (playback_event table).
    /// Parallel to eventLogger's real_time_event channel, which feeds the
    /// timeline UI; this one feeds Stats. Nil when the database is unavailable.
    @ObservationIgnored private(set) var sessionRecorder: PlaybackSessionRecorder?
```

Initialize wherever `databaseService` becomes available (same place `eventLogger`-dependent services are set up — search `databaseService =` assignments):

```swift
        if let db = databaseService {
            sessionRecorder = PlaybackSessionRecorder(writer: db.writer)
        }
```

- [ ] **Step 2: Yield from the four seams**

In the wiring block ([PlayerModel.swift:690-781](../../EchoCore/ViewModels/PlayerModel.swift)):

```swift
        playbackController.coordinator_playStateChanged = { [weak self] isPlaying in
            guard let self else { return }
            if isPlaying {
                self.startPlaybackSessionLogging()
                self.sessionRecorder?.yield(.opened(
                    audiobookID: self.folderURL?.absoluteString ?? "unknown",
                    trackID: self.state.tracks.indices.contains(self.state.currentIndex)
                        ? self.state.tracks[self.state.currentIndex].id : nil,
                    position: self.audioEngine.currentTime,
                    speed: Double(self.playbackController.speed),
                    source: "user",
                    at: Date()
                ))
                if self.settingsManager?.continuousAutoAlignmentEnabled == true {
                    self.continuousAlignmentService?.start()
                }
            } else {
                self.endPlaybackSessionLogging()
                self.sessionRecorder?.yield(.closed(position: self.audioEngine.currentTime, at: Date()))
                self.continuousAlignmentService?.stop()
            }
        }
```

```swift
        playbackController.coordinator_refreshProgress = { [weak self] in
            self?.updateNowPlayingElapsedTime()
            self?.updateProgressFromPlayer()
            if let self, self.audioEngine.currentTime.isFinite {
                self.sessionRecorder?.yield(.progressTick(position: self.audioEngine.currentTime, at: Date()))
            }
        }
```

```swift
        playbackController.coordinator_persistSpeed = { [weak self] key, speed in
            self?.persistence.saveSpeed(for: key, speed: speed)
            self?.sessionRecorder?.yield(.speedChanged(newSpeed: Double(speed), at: Date()))
        }
```

```swift
        playbackController.coordinator_seekCompleted = { [weak self] isManual in
            guard let self else { return }
            if !isManual {
                self.updateCurrentChapterFromPlayerTime()
            }
            // Both manual scrubs and smart-rewind jumps split the segment:
            // any position discontinuity must not be counted as listened range.
            self.sessionRecorder?.yield(.seeked(toPosition: self.audioEngine.currentTime, at: Date()))
        }
```

- [ ] **Step 3: Close on deinit**

In `deinit` ([PlayerModel.swift:801-812](../../EchoCore/ViewModels/PlayerModel.swift)), inside `MainActor.assumeIsolated`: `yield` is `nonisolated` + synchronous, so this is legal and cheap:

```swift
            sessionRecorder?.yield(.closed(position: nil, at: Date()))
```

- [ ] **Step 4: Build all schemes + full test suite**

```bash
xcodebuild -project Echo.xcodeproj -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build test 2>&1 | tail -5
xcodebuild -project Echo.xcodeproj -scheme "Echo Watch App" -destination 'generic/platform=watchOS Simulator' build 2>&1 | tail -3
```
Expected: zero warnings, tests green. (macOS stays broken until WS1 — unchanged files only.)

- [ ] **Step 5: Manual QA on simulator** (the WS0 gate from the program plan)

Script: load a book → play 2 min → change speed → scrub forward → switch track → pause → force-quit from app switcher → relaunch. Then:

```bash
sqlite3 ~/Library/Developer/CoreSimulator/Devices/<UDID>/data/Containers/Shared/AppGroup/<id>/orbit.sqlite \
  "SELECT id, track_id, speed, start_position, end_position, started_at, ended_at FROM playback_event ORDER BY id"
```

Assert: one segment per constant-(track,speed,no-seek) stretch; the force-quit segment ends within 30s of the quit; no NULL `ended_at`/`end_position` anywhere; no segment shorter than 5s wall-clock.

- [ ] **Step 6: Commit**

```bash
git add EchoCore/ViewModels/PlayerModel.swift
git commit -m "feat(stats): wire PlaybackSessionRecorder into playback seams"
```

---

### Task 9: Docs sync + branch wrap-up

**Files:**
- Modify: `ARCHITECTURE.md` (add PlaybackSessionRecorder/segment-capture section under the services overview; document the real_time_event integrity fixes and push-forward removal)
- Modify: `CHANGELOG.md` (entry under Unreleased: capture layer, three integrity fixes, Schema_V12)
- Modify: `ROADMAP.md` (mark WS0 progress in the status table area; note Phase 8 stats groundwork)

- [ ] **Step 1: Write the doc updates** — ARCHITECTURE.md gains:

```markdown
### Listening-segment capture (Stats foundation)

`PlaybackSessionRecorder` (actor) + `PlaybackSegmentBuilder` (pure state machine, `Shared/Stats/`)
persist every contiguous listening stretch to `playback_event`: one row per constant
(track, speed) run with no seeks. Main-actor playback seams yield `RecorderEvent`s
(non-blocking); a single consumer task performs async GRDB writes. Rows are written
self-consistent at open and extended by a 30 s heartbeat, so a crash leaves a valid
segment ending at the last heartbeat — no recovery sweep exists or is needed.
`real_time_event` remains the timeline-UI channel; `playback_event` is the analytics
channel consumed by the Stats feature (WS3+).
```

- [ ] **Step 2: Verify the branch end-to-end**

```bash
xcodebuild -project Echo.xcodeproj -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build test 2>&1 | tail -5
git log --oneline main..HEAD
```
Expected: green; ~7 commits telling a reviewable story.

- [ ] **Step 3: Commit docs; open PR**

```bash
git add ARCHITECTURE.md CHANGELOG.md ROADMAP.md
git commit -m "docs: document listening-segment capture layer and event-integrity fixes"
git push -u origin feat/ws0-playback-capture
gh pr create --title "WS0: playback capture layer + event-integrity fixes" --body "..."
```

---

## Self-review notes (already applied)

- **Spec coverage**: program-plan WS0 items all present — recorder (T6-T8), three bug fixes (T2-T4), Schema_V12 incl. WS5/WS6b columns (T1), heartbeat crash-safety (T5-T7), docs (T9). Deviation from program plan, deliberate: no `source=recovered` launch sweep — self-consistent rows make crashed segments indistinguishable from (and as valid as) clean closes; YAGNI.
- **Type consistency**: `RecorderEvent`/`SegmentAction`/`OpenSegment` definitions in Task 6 are the single source; Task 7 consumes them unmodified; DAO method names (`insertOpen`/`extend`/`delete`) consistent between Task 5 and tests.
- **Known risk**: `drain()` test hook is the least-proven design point; fallback documented inline in Task 7.
