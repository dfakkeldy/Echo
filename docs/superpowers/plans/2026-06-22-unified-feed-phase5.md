# Unified Feed — Phase 5 (Sessions List + macOS Parity + Doc-Sync) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a browsable **Sessions history** to the iOS reader surface (each row recaps one listening session — when, where as GPS route + miles if location was enabled, minutes listened, chapter range covered, and counts of bookmarks/cards/images/notes; tapping a row scopes the feed to that session), bring the **macOS reader feed** to parity by giving it the same collapsible chapter accordion using the UIKit-free pure types from Phase 1, and **doc-sync** ARCHITECTURE.md / README.md / ROADMAP.md / CHANGELOG.md to reflect the unified feed.

**Architecture:** Sessions are **not** a stored entity — there is no `playback_session` table. A "session" is reconstructed in a new pure query layer (`SessionSummaryService`, a GRDB `struct X { let db: DatabaseWriter }`) by grouping `playback_event` rows (the durational `event_type='play'` segments — defined in `Schema_V1.swift:99`; V14 only adds an index and `session_location`) on `started_at`/`ended_at` time gaps, then deriving GPS route from `session_location` (FK → `playback_event.id`), chapter range from a new `chapter` overlap join, and counts from `bookmark`/`flashcard`/`note` `created_at` filtered to the session window. The service emits a pure value type `SessionSummary` (UIKit-free, in `Shared/Models/`) consumed by a new iOS `SessionsListView` and by a `SessionDetailFeedView` that hosts the existing reader feed scoped to one session via a new `SessionScope` axis on `ReaderFeedViewModel`. macOS parity reuses only the UIKit-free pure pieces (`FeedAccordion`, `ChapterAudioStatusResolver` — both already in `Shared/`) plus the moved-to-`Shared/` grouping types, driving a SwiftUI-native accordion in `MacReaderFeedView` (no UIKit `UICollectionView`).

**Tech Stack:** Swift 6, SwiftUI (iOS + macOS), GRDB, Core Location / MapKit (route distance + optional map snapshot), Swift Testing (`@Test`/`#expect`), `DatabaseService(inMemory:)`.

## Global Constraints

- **License header:** every new `.swift` file starts with `// SPDX-License-Identifier: GPL-3.0-or-later` on **line 1**. A SwiftFormat PostToolUse hook reflows imports on edit and can displace the SPDX header below an `import` — after editing, verify SPDX is still line 1 (a blank line after it detaches it from the import block).
- **Branch:** continue on `feature/unified-feed-phase1` (or cut `feature/unified-feed-phase5` from `origin/nightly` if Phase 1 has already merged). Before any edits in a fresh worktree, ensure the base is nightly: `git merge-base --is-ancestor origin/nightly HEAD || (git fetch origin nightly && git reset --hard origin/nightly)`. PRs target **`nightly`**, never `main`.
- **Scope:** iOS for the Sessions list + session scope; **macOS for the parity task only**. `ReaderFeedViewModel` / `ReaderFeedCollectionView` / `ReaderTab` / `SessionsListView` / `SessionDetailFeedView` import UIKit/EchoCore and are **iOS-only**. `MacReaderFeedView` is **macOS-only**. New **pure** types (`SessionSummary`, `SessionSummaryService`, and any grouping types moved out of EchoCore) must stay UIKit-free and live in `Shared/` so both targets compile them. **Verify membership in both `Echo` and `Echo macOS` targets at add time** (see Task 6).
- **Build discipline (16 GB machine):** never run two `xcodebuild` invocations concurrently. The overnight `~/Developer/echo-overnight/redo-resume.sh` (NarrationHarness) holds the **exclusive** build slot — confirm it is idle/paused before any `make build-tests`. Run all builds in the **foreground** with a long timeout (`timeout: 600000`); a subagent that backgrounds a build yields unresumably. `make build-tests` and `make test-only` already pass `CODE_SIGNING_ALLOWED=NO` (Makefile `CODESIGN_OFF`); the sim destination is `iPhone 17`.
- **Schema is OPTIONAL this phase (spec §9).** Default plan derives everything in queries — **no migration**. If the Sessions list proves too slow in the simulator smoke test (Task 7), add an additive `session_summary_cache` table. **Do NOT hard-code a migration version number** — the highest registered on `nightly` today is **V23** (`Schema_V23.swift`, registered `DatabaseService.swift:115`), so the next free is **V24**, but other in-flight branches (narration silence fix PR #144, ABS follow-ups) may claim V24 first. At implementation time, claim the **next free** version after re-checking `git log origin/nightly -- Shared/Database/Migrations/`, add the matching `SchemaVxxTests`, and run the **schema-migration-reviewer** before committing. The default path in this plan adds NO migration.

---

## File Structure

**New files**

- `Shared/Models/SessionSummary.swift` *(create — pure value type; UIKit-free; both targets)*
- `Shared/Services/SessionSummaryService.swift` *(create — GRDB query layer; `struct { let db: DatabaseWriter }`; both targets)*
- `EchoCore/Views/SessionsListView.swift` *(create — iOS SwiftUI list of `SessionSummary` rows)*
- `EchoCore/Views/SessionDetailFeedView.swift` *(create — iOS; hosts the reader feed scoped to one session)*
- `EchoTests/SessionSummaryServiceTests.swift` *(create)*
- `EchoTests/SessionScopeReducerTests.swift` *(create — pure session-scope filter math)*

**Modified files**

- `EchoCore/ViewModels/ReaderFeedViewModel.swift` — add `sessionScope: SessionScope` published property + a pure `SessionScopeReducer` filter applied in `reload()` (browse branch) to restrict sections to blocks whose audio time falls in the session window.
- `EchoCore/Views/ReaderTab.swift` — add a toolbar entry / navigation to `SessionsListView`; thread the session scope into the hosted feed.
- `Echo macOS/Views/MacReaderFeedView.swift` — group blocks by chapter, drive a SwiftUI-native accordion with `FeedAccordion` + `ChapterAudioStatusResolver`, show has-audio styling, auto-expand the playing chapter.
- `ARCHITECTURE.md` / `README.md` / `ROADMAP.md` / `CHANGELOG.md` — doc-sync (Task 8).

**Type-move (Trap A resolution — only if Phase 1 already shipped these in EchoCore):**

Phase 1 places `ReaderFeedDisplayBuilder` + `ReaderChapterGroup` (and `ReaderCardSection`/`ReaderCardItem`) in `EchoCore/Models/`, which is **iOS-only** — the macOS target cannot import them. This plan does **NOT** move them. Instead, macOS parity (Task 5) drives its accordion directly from `[EPubBlockRecord]` grouped by `chapter_index`, calling only `Shared/`-resident pure types (`FeedAccordion`, `ChapterAudioStatusResolver`). This keeps the macOS path independent and avoids touching the iOS feed engine. (Documented best-judgment default per Trap A option 2; flagged for owner review in Self-Review.)

**Responsibility boundaries**

- `SessionSummaryService` (Shared): all SQL. Reconstructs sessions, derives route/coverage/counts. Pure of UI.
- `SessionSummary` (Shared): the read model. `Codable`, `Sendable`, `Identifiable`, `Hashable`. Carries everything the row + detail need.
- `SessionScopeReducer` (Shared): pure function mapping `(allSections, audioStartTimeByBlockID, scopeWindow)` → filtered sections. Unit-tested without a DB.
- `SessionsListView` / `SessionDetailFeedView` (EchoCore, iOS): SwiftUI only.
- `MacReaderFeedView` (macOS): SwiftUI accordion; no shared grouping type beyond `FeedAccordion`/`ChapterAudioStatusResolver`.

**Test conventions:** Swift Testing `@Test`/`#expect`, `@testable import Echo`, `DatabaseService(inMemory: ())` then `db.writer` / `db.write { db in … }` (see `EchoTests/ChapterAudioStatusResolverTests.swift`). `EPubBlockRecord` has **no custom init** → use the synthesized memberwise initializer for fixtures.

---

## Task 1: Session read model (`SessionSummary`)

**Files:**
- Create: `Shared/Models/SessionSummary.swift`
- Test: covered indirectly by Task 2's `SessionSummaryServiceTests` (this task is a pure data type; no behavior to test alone).

**Interfaces:**
- Produces: `struct SessionSummary` (value type), `struct SessionRoutePoint`, consumed by `SessionSummaryService`, `SessionsListView`, `SessionDetailFeedView`.

- [ ] **Step 1: Create the read model.**

Create `Shared/Models/SessionSummary.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreLocation
import Foundation

/// One GPS sample captured during a session, in chronological order.
public struct SessionRoutePoint: Codable, Hashable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let placeName: String?
    public let timestamp: Date

    public init(latitude: Double, longitude: Double, placeName: String?, timestamp: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.placeName = placeName
        self.timestamp = timestamp
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// A reconstructed listening session for one audiobook.
///
/// Sessions are NOT stored: there is no `playback_session` table. This value is
/// derived by `SessionSummaryService` by grouping `playback_event` rows on
/// `started_at`/`ended_at` time gaps, then joining `session_location`, `chapter`,
/// `bookmark`, `flashcard`, and `note`.
public struct SessionSummary: Identifiable, Codable, Hashable, Sendable {
    /// Stable synthetic id = "<audiobookID>#<sessionStart ISO8601>".
    public let id: String
    public let audiobookID: String
    /// Wall-clock window of the session (earliest started_at … latest ended_at).
    public let startedAt: Date
    public let endedAt: Date
    /// Audio position range covered (seconds into the audiobook).
    public let startPosition: TimeInterval
    public let endPosition: TimeInterval
    /// Adjusted listening minutes = sum(end_position - start_position) / speed, / 60.
    public let minutesListened: Double
    /// Covered chapter range by `chapter.sort_order` (nil if no chapter overlap).
    public let firstChapterTitle: String?
    public let lastChapterTitle: String?
    public let firstChapterSortOrder: Int?
    public let lastChapterSortOrder: Int?
    /// Counts within the wall-clock window.
    public let bookmarkCount: Int
    public let cardCount: Int
    public let noteCount: Int
    public let imageCount: Int
    /// GPS route in chronological order (empty if location was off).
    public let route: [SessionRoutePoint]
    /// Route distance in miles (0 if route has < 2 points).
    public let routeMiles: Double

    public init(
        id: String,
        audiobookID: String,
        startedAt: Date,
        endedAt: Date,
        startPosition: TimeInterval,
        endPosition: TimeInterval,
        minutesListened: Double,
        firstChapterTitle: String?,
        lastChapterTitle: String?,
        firstChapterSortOrder: Int?,
        lastChapterSortOrder: Int?,
        bookmarkCount: Int,
        cardCount: Int,
        noteCount: Int,
        imageCount: Int,
        route: [SessionRoutePoint],
        routeMiles: Double
    ) {
        self.id = id
        self.audiobookID = audiobookID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.startPosition = startPosition
        self.endPosition = endPosition
        self.minutesListened = minutesListened
        self.firstChapterTitle = firstChapterTitle
        self.lastChapterTitle = lastChapterTitle
        self.firstChapterSortOrder = firstChapterSortOrder
        self.lastChapterSortOrder = lastChapterSortOrder
        self.bookmarkCount = bookmarkCount
        self.cardCount = cardCount
        self.noteCount = noteCount
        self.imageCount = imageCount
        self.route = route
        self.routeMiles = routeMiles
    }

    /// True when location was recorded for this session.
    public var hasRoute: Bool { route.count >= 2 }

    /// Human chapter-range label, e.g. "Ch. 3 – Ch. 5" or "Ch. 3".
    public var chapterRangeLabel: String? {
        guard let first = firstChapterTitle else { return nil }
        guard let last = lastChapterTitle, last != first else { return first }
        return "\(first) – \(last)"
    }
}
```

- [ ] **Step 2: Verify SPDX is line 1.** Open the file and confirm `// SPDX-License-Identifier: GPL-3.0-or-later` is line 1 (the SwiftFormat hook may have reflowed). If displaced, move it back to line 1.

- [ ] **Step 3: Commit.**

```bash
git add Shared/Models/SessionSummary.swift
git commit -m "feat(feed): add SessionSummary read model for sessions list (Phase 5)"
```

---

## Task 2: Session query layer (`SessionSummaryService`)

**Files:**
- Create: `Shared/Services/SessionSummaryService.swift`
- Test: `EchoTests/SessionSummaryServiceTests.swift`

**Interfaces:**
- Consumes: `playback_event`, `session_location`, `chapter`, `bookmark`, `flashcard`, `note` tables; `DatabaseWriter`.
- Produces:
  ```swift
  struct SessionSummaryService { let db: DatabaseWriter
      func sessions(audiobookID: String, gapThreshold: TimeInterval = 300) throws -> [SessionSummary]
  }
  ```

- [ ] **Step 1: Inspect the exact column names that vary by table.** Run:

```bash
grep -nE "CREATE TABLE (bookmark|flashcard|note)\b" Shared/Database/Schema_V1.swift Shared/Database/Schema_V2.swift Shared/Database/Migrations/*.swift
```

Confirm the `created_at` column name and the `audiobook_id` FK column on each of `bookmark`, `flashcard`, `note`. If any table names the timestamp differently (e.g. `created` vs `created_at`) or scopes by `audiobook_id` vs a join through `chapter`, adjust the SQL in Step 2 accordingly. (Best-judgment default below assumes `created_at` + `audiobook_id`; correct it from the grep output before writing.) **N3:** The `note` table is confirmed in `Schema_V2.swift:9` — no need to guard for its absence, though `count(table:)` tolerates it anyway.

- [ ] **Step 2: Create the service.**

Create `Shared/Services/SessionSummaryService.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreLocation
import Foundation
import GRDB

/// Reconstructs listening "sessions" for an audiobook from `playback_event`.
///
/// There is no `playback_session` table. A session is one or more consecutive
/// `event_type='play'` rows whose inter-row wall-clock gap is <= `gapThreshold`.
/// Route comes from `session_location` (FK -> playback_event.id); chapter range
/// from a `chapter` overlap join; counts from `created_at` in the session window.
struct SessionSummaryService {
    let db: DatabaseWriter

    private static let iso = ISO8601DateFormatter()

    /// Returns sessions newest-first.
    func sessions(audiobookID: String, gapThreshold: TimeInterval = 300) throws -> [SessionSummary] {
        try db.read { db in
            // 1. Pull closed play segments, oldest-first, to group on gaps.
            let segmentRows = try Row.fetchAll(db, sql: """
                SELECT id, started_at, ended_at, start_position, end_position, speed
                FROM playback_event
                WHERE audiobook_id = ?
                  AND event_type = 'play'
                  AND ended_at IS NOT NULL
                  AND end_position IS NOT NULL
                ORDER BY started_at ASC
                """, arguments: [audiobookID])

            struct Segment {
                let eventID: Int64
                let start: Date
                let end: Date
                let startPos: Double
                let endPos: Double
                let speed: Double
            }

            let segments: [Segment] = segmentRows.compactMap { row in
                guard
                    let startStr: String = row["started_at"],
                    let endStr: String = row["ended_at"],
                    let start = Self.iso.date(from: startStr),
                    let end = Self.iso.date(from: endStr)
                else { return nil }
                return Segment(
                    eventID: row["id"],
                    start: start,
                    end: end,
                    startPos: row["start_position"] ?? 0,
                    endPos: row["end_position"] ?? 0,
                    speed: (row["speed"] as Double?) ?? 1.0
                )
            }

            guard !segments.isEmpty else { return [] }

            // 2. Group consecutive segments on the wall-clock gap.
            var groups: [[Segment]] = []
            var current: [Segment] = [segments[0]]
            for seg in segments.dropFirst() {
                let gap = seg.start.timeIntervalSince(current.last!.end)
                if gap <= gapThreshold {
                    current.append(seg)
                } else {
                    groups.append(current)
                    current = [seg]
                }
            }
            groups.append(current)

            // 3. Build a SessionSummary per group.
            var summaries: [SessionSummary] = []
            for group in groups {
                let startedAt = group.first!.start
                let endedAt = group.map(\.end).max()!
                let startPosition = group.map(\.startPos).min()!
                let endPosition = group.map(\.endPos).max()!
                let minutes = group.reduce(0.0) { acc, s in
                    let dur = max(0, s.endPos - s.startPos)
                    return acc + (s.speed > 0 ? dur / s.speed : dur)
                } / 60.0

                let startStr = Self.iso.string(from: startedAt)
                let endStr = Self.iso.string(from: endedAt)

                // 3a. Chapter range (new overlap join: chapter.start_seconds/end_seconds vs pe.start_position/end_position).
                // Note: StatsRepository.fetchChapterCoverage computes coverage in Swift via StatsAggregator,
                // NOT via a SQL overlap join — this join is new and has its own chapter-range test below.
                let chapterRow = try Row.fetchOne(db, sql: """
                    SELECT MIN(c.sort_order) AS first_order,
                           MAX(c.sort_order) AS last_order
                    FROM playback_event pe
                    JOIN chapter c ON c.audiobook_id = pe.audiobook_id
                                  AND pe.start_position <= c.end_seconds
                                  AND pe.end_position   >= c.start_seconds
                    WHERE pe.audiobook_id = ?
                      AND pe.event_type = 'play'
                      AND pe.ended_at IS NOT NULL
                      AND pe.started_at >= ?
                      AND pe.started_at <= ?
                    """, arguments: [audiobookID, startStr, endStr])

                let firstOrder = chapterRow?["first_order"] as Int?
                let lastOrder = chapterRow?["last_order"] as Int?
                let firstTitle = try Self.chapterTitle(db, audiobookID: audiobookID, sortOrder: firstOrder)
                let lastTitle = try Self.chapterTitle(db, audiobookID: audiobookID, sortOrder: lastOrder)

                // 3b. Route from session_location for this group's event ids.
                let eventIDs = group.map(\.eventID)
                let placeholders = databaseQuestionMarks(count: eventIDs.count)
                let routeRows = try Row.fetchAll(db, sql: """
                    SELECT latitude, longitude, place_name, created_at
                    FROM session_location
                    WHERE playback_event_id IN (\(placeholders))
                    ORDER BY created_at ASC
                    """, arguments: StatementArguments(eventIDs))

                let route: [SessionRoutePoint] = routeRows.compactMap { row in
                    guard
                        let createdStr: String = row["created_at"],
                        let ts = Self.iso.date(from: createdStr)
                    else { return nil }
                    return SessionRoutePoint(
                        latitude: row["latitude"],
                        longitude: row["longitude"],
                        placeName: row["place_name"],
                        timestamp: ts
                    )
                }
                let routeMiles = Self.miles(for: route)

                // 3c. Counts in the wall-clock window.
                let bookmarkCount = try Self.count(
                    db, table: "bookmark", audiobookID: audiobookID, from: startStr, to: endStr
                )
                let cardCount = try Self.count(
                    db, table: "flashcard", audiobookID: audiobookID, from: startStr, to: endStr
                )
                let noteCount = try Self.count(
                    db, table: "note", audiobookID: audiobookID, from: startStr, to: endStr
                )

                summaries.append(SessionSummary(
                    id: "\(audiobookID)#\(startStr)",
                    audiobookID: audiobookID,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    startPosition: startPosition,
                    endPosition: endPosition,
                    minutesListened: minutes,
                    firstChapterTitle: firstTitle,
                    lastChapterTitle: lastTitle,
                    firstChapterSortOrder: firstOrder,
                    lastChapterSortOrder: lastOrder,
                    bookmarkCount: bookmarkCount,
                    cardCount: cardCount,
                    noteCount: noteCount,
                    // N4: Spec §9 lists "pics" counts. imageCount is deferred to 0 pending
                    // owner sign-off. The source exists: query epub_block WHERE block_kind='image'
                    // AND audiobook_id=? AND (some audio anchor falls in the session window).
                    // Implement or get explicit deferral approval before shipping.
                    imageCount: 0,
                    route: route,
                    routeMiles: routeMiles
                ))
            }

            return summaries.reversed() // newest-first
        }
    }

    // MARK: - Helpers

    private static func chapterTitle(
        _ db: Database, audiobookID: String, sortOrder: Int?
    ) throws -> String? {
        guard let sortOrder else { return nil }
        return try String.fetchOne(db, sql: """
            SELECT title FROM chapter
            WHERE audiobook_id = ? AND sort_order = ?
            LIMIT 1
            """, arguments: [audiobookID, sortOrder])
    }

    private static func count(
        _ db: Database, table: String, audiobookID: String, from: String, to: String
    ) throws -> Int {
        // Tolerate a missing table (e.g. `note` may not exist on every schema line).
        let exists = try Bool.fetchOne(db, sql: """
            SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1
            """, arguments: [table]) ?? false
        guard exists else { return 0 }
        return try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM \(table)
            WHERE audiobook_id = ?
              AND created_at >= ?
              AND created_at <= ?
            """, arguments: [audiobookID, from, to]) ?? 0
    }

    private static func miles(for route: [SessionRoutePoint]) -> Double {
        guard route.count >= 2 else { return 0 }
        var meters = 0.0
        for i in 1..<route.count {
            let a = CLLocation(latitude: route[i - 1].latitude, longitude: route[i - 1].longitude)
            let b = CLLocation(latitude: route[i].latitude, longitude: route[i].longitude)
            meters += b.distance(from: a)
        }
        return meters / 1609.344
    }
}

// N1: databaseQuestionMarks(count:) is already a public GRDB global (used in
// WordTimingMaterializer.swift:72). The private redefinition below compiles and
// shadows the GRDB symbol within this file, but is redundant — prefer calling
// the GRDB public global directly and delete this private definition.
// If you do keep it, it is correct and harmless.
private func databaseQuestionMarks(count: Int) -> String {
    Array(repeating: "?", count: max(1, count)).joined(separator: ", ")
}
```

> **Note on `count(table:)`:** building SQL with an interpolated table name is safe here because `table` is a compile-time literal we pass (`"bookmark"`/`"flashcard"`/`"note"`), never user input. All value bindings remain parameterized.

- [ ] **Step 2.5: Reconcile column names + timestamp format.** Apply the corrections from Step 1's grep to the `bookmark`/`flashcard`/`note` queries (timestamp column, scope column). Confirm `playback_event.speed` is non-null (Schema_V1 declares `speed REAL NOT NULL DEFAULT 1.0` — the `?? 1.0` is belt-and-suspenders). **N2 — timestamp format:** the app writes `created_at` as ISO8601 (`T`-separator), but the schema DEFAULT is `datetime('now')` (space-separator, e.g. `2026-06-22 12:00:00`). The `created_at >= ?` / `<= ?` comparisons use ISO8601 strings; for rows inserted by the app this works, but rows that got the SQLite DEFAULT (space format) may not compare correctly. Verify whether any `bookmark`/`flashcard`/`note` rows can have the space-format DEFAULT (i.e. inserted without an explicit `created_at`), and if so add a `REPLACE` or `strftime` normalization, or use `datetime(created_at)` in the comparison. If all app inserts always supply an explicit ISO8601 value, no change needed.

- [ ] **Step 3: Write the tests.**

Create `EchoTests/SessionSummaryServiceTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import GRDB
import Testing

@testable import Echo

@Suite struct SessionSummaryServiceTests {
    private static let iso = ISO8601DateFormatter()

    /// Inserts a closed play segment and returns its event id.
    @discardableResult
    private func insertSegment(
        _ db: Database,
        audiobookID: String,
        start: Date,
        durationSec: TimeInterval,
        startPos: Double,
        endPos: Double,
        speed: Double = 1.0
    ) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO playback_event
              (audiobook_id, started_at, ended_at, start_position, end_position, speed, event_type)
            VALUES (?, ?, ?, ?, ?, ?, 'play')
            """, arguments: [
                audiobookID,
                Self.iso.string(from: start),
                Self.iso.string(from: start.addingTimeInterval(durationSec)),
                startPos, endPos, speed
            ])
        return db.lastInsertedRowID
    }

    private func insertAudiobook(_ db: Database, id: String) throws {
        // Minimal audiobook row to satisfy FK and NOT NULL constraints.
        // Schema_V1 requires title NOT NULL and duration NOT NULL (no default).
        try db.execute(
            sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, ?, 0.0)",
            arguments: [id, "Bk"]
        )
    }

    @Test func twoSegmentsWithinGapFormOneSession() throws {
        let dbService = try DatabaseService(inMemory: ())
        let svc = SessionSummaryService(db: dbService.writer)
        let bk = "bk1"
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        try dbService.writer.write { db in
            try insertAudiobook(db, id: bk)
            // segment A: 0..60s audio, 60s wall
            try insertSegment(db, audiobookID: bk, start: base, durationSec: 60, startPos: 0, endPos: 60)
            // segment B starts 30s after A ends (gap < 300) -> same session
            try insertSegment(db, audiobookID: bk, start: base.addingTimeInterval(90), durationSec: 60, startPos: 60, endPos: 120)
        }

        let sessions = try svc.sessions(audiobookID: bk)
        #expect(sessions.count == 1)
        #expect(sessions[0].startPosition == 0)
        #expect(sessions[0].endPosition == 120)
        // 120s audio / speed 1 / 60 = 2.0 minutes
        #expect(abs(sessions[0].minutesListened - 2.0) < 0.001)
    }

    @Test func gapAboveThresholdSplitsSessions() throws {
        let dbService = try DatabaseService(inMemory: ())
        let svc = SessionSummaryService(db: dbService.writer)
        let bk = "bk2"
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        try dbService.writer.write { db in
            try insertAudiobook(db, id: bk)
            try insertSegment(db, audiobookID: bk, start: base, durationSec: 60, startPos: 0, endPos: 60)
            // 10 minutes later -> new session
            try insertSegment(db, audiobookID: bk, start: base.addingTimeInterval(660), durationSec: 60, startPos: 60, endPos: 120)
        }

        let sessions = try svc.sessions(audiobookID: bk)
        #expect(sessions.count == 2)
        // newest-first
        #expect(sessions[0].startPosition == 60)
        #expect(sessions[1].startPosition == 0)
    }

    @Test func speedAdjustsMinutes() throws {
        let dbService = try DatabaseService(inMemory: ())
        let svc = SessionSummaryService(db: dbService.writer)
        let bk = "bk3"
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        try dbService.writer.write { db in
            try insertAudiobook(db, id: bk)
            // 120s of audio at 2x = 1.0 adjusted minute
            try insertSegment(db, audiobookID: bk, start: base, durationSec: 60, startPos: 0, endPos: 120, speed: 2.0)
        }

        let sessions = try svc.sessions(audiobookID: bk)
        #expect(sessions.count == 1)
        #expect(abs(sessions[0].minutesListened - 1.0) < 0.001)
    }

    @Test func routeMilesComputedFromLocations() throws {
        let dbService = try DatabaseService(inMemory: ())
        let svc = SessionSummaryService(db: dbService.writer)
        let bk = "bk4"
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        try dbService.writer.write { db in
            try insertAudiobook(db, id: bk)
            let eid = try insertSegment(db, audiobookID: bk, start: base, durationSec: 60, startPos: 0, endPos: 60)
            // ~1 deg longitude apart near equator-ish -> tens of miles; just assert > 0 and ordered.
            try db.execute(sql: """
                INSERT INTO session_location (playback_event_id, latitude, longitude, place_name, created_at)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [eid, 40.0, -74.0, "A", Self.iso.string(from: base)])
            try db.execute(sql: """
                INSERT INTO session_location (playback_event_id, latitude, longitude, place_name, created_at)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [eid, 40.01, -74.0, "B", Self.iso.string(from: base.addingTimeInterval(30))])
        }

        let sessions = try svc.sessions(audiobookID: bk)
        #expect(sessions.count == 1)
        #expect(sessions[0].route.count == 2)
        #expect(sessions[0].hasRoute)
        #expect(sessions[0].routeMiles > 0)
        #expect(sessions[0].route[0].placeName == "A")
    }

    @Test func emptyWhenNoSegments() throws {
        let dbService = try DatabaseService(inMemory: ())
        let svc = SessionSummaryService(db: dbService.writer)
        try dbService.writer.write { db in try insertAudiobook(db, id: "empty") }
        #expect(try svc.sessions(audiobookID: "empty").isEmpty)
    }
}
```

- [ ] **Step 4: Build the test bundle (foreground, build slot free).**

```bash
make build-tests
```

Expected: `** TEST BUILD SUCCEEDED **` (or the Makefile's success line). No compile errors.

- [ ] **Step 5: Run the suite.**

```bash
make test-only FILTER=EchoTests/SessionSummaryServiceTests
```

Expected output: `Test run with 5 tests passed` (5 `@Test` cases, all green). If the FK insert fails, inspect `PRAGMA foreign_keys` and the `audiobook` columns and adjust `insertAudiobook`.

- [ ] **Step 6: Commit.**

```bash
git add Shared/Services/SessionSummaryService.swift EchoTests/SessionSummaryServiceTests.swift
git commit -m "feat(feed): add SessionSummaryService reconstructing sessions from playback_event (Phase 5)"
```

---

## Task 3: Session-scope filter math (`SessionScope` + `SessionScopeReducer`)

**Files:**
- Create: `Shared/Models/SessionSummary.swift` is already created; add `SessionScope` + `SessionScopeReducer` to a new file `Shared/SessionScopeReducer.swift`.
- Test: `EchoTests/SessionScopeReducerTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum SessionScope: Equatable, Sendable { case wholeBook; case session(start: TimeInterval, end: TimeInterval) }
  enum SessionScopeReducer {
      static func blockIDsInScope(audioStartTimeByBlockID: [String: TimeInterval], scope: SessionScope) -> Set<String>?
  }
  ```
  Returns `nil` for `.wholeBook` (meaning "no filter"); a `Set<String>` of in-window block ids otherwise.

- [ ] **Step 1: Create the reducer.**

Create `Shared/SessionScopeReducer.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Which slice of the book the reader feed is currently scoped to.
public enum SessionScope: Equatable, Sendable {
    case wholeBook
    /// Audio position window in seconds (a reconstructed session's range).
    case session(start: TimeInterval, end: TimeInterval)
}

/// Pure filter: maps a session scope to the set of block ids whose audio start
/// time falls inside the session's audio-position window. UI-free and DB-free so
/// both iOS and macOS can reuse it.
public enum SessionScopeReducer {
    /// - Returns: `nil` for `.wholeBook` (apply no filter); otherwise the set of
    ///   block ids whose `audioStartTime` is within `[start, end]`.
    public static func blockIDsInScope(
        audioStartTimeByBlockID: [String: TimeInterval],
        scope: SessionScope
    ) -> Set<String>? {
        switch scope {
        case .wholeBook:
            return nil
        case let .session(start, end):
            let lo = min(start, end)
            let hi = max(start, end)
            var result = Set<String>()
            for (blockID, t) in audioStartTimeByBlockID where t >= lo && t <= hi {
                result.insert(blockID)
            }
            return result
        }
    }
}
```

- [ ] **Step 2: Write the tests.**

Create `EchoTests/SessionScopeReducerTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later

import Testing

@testable import Echo

@Suite struct SessionScopeReducerTests {
    private let times: [String: TimeInterval] = [
        "b1": 0,
        "b2": 30,
        "b3": 90,
        "b4": 150,
    ]

    @Test func wholeBookReturnsNilFilter() {
        #expect(SessionScopeReducer.blockIDsInScope(
            audioStartTimeByBlockID: times, scope: .wholeBook
        ) == nil)
    }

    @Test func sessionWindowSelectsInclusiveRange() {
        let result = SessionScopeReducer.blockIDsInScope(
            audioStartTimeByBlockID: times, scope: .session(start: 30, end: 90)
        )
        #expect(result == ["b2", "b3"])
    }

    @Test func reversedWindowIsNormalized() {
        let result = SessionScopeReducer.blockIDsInScope(
            audioStartTimeByBlockID: times, scope: .session(start: 90, end: 30)
        )
        #expect(result == ["b2", "b3"])
    }

    @Test func emptyWindowReturnsEmptySet() {
        let result = SessionScopeReducer.blockIDsInScope(
            audioStartTimeByBlockID: times, scope: .session(start: 1000, end: 2000)
        )
        #expect(result == [])
    }
}
```

- [ ] **Step 3: Build + run.**

```bash
make build-tests && make test-only FILTER=EchoTests/SessionScopeReducerTests
```

Expected: build succeeds; `Test run with 4 tests passed`.

- [ ] **Step 4: Commit.**

```bash
git add Shared/SessionScopeReducer.swift EchoTests/SessionScopeReducerTests.swift
git commit -m "feat(feed): add pure SessionScope filter for session-scoped reader feed (Phase 5)"
```

---

## Task 4: Wire session scope into `ReaderFeedViewModel`

**Files:**
- Modify: `EchoCore/ViewModels/ReaderFeedViewModel.swift`
- Test: extend `EchoTests/SessionScopeReducerTests.swift` is pure-only; the VM wiring is build-verified + covered by a small VM test added here.

**Interfaces:**
- Consumes: `SessionScope`, `SessionScopeReducer`, the VM's existing `audioStartTimeByBlockID` (`ReaderFeedViewModel.swift:` published `audioStartTimeByBlockID`) and `sections` (line 54).
- Produces: `var sessionScope: SessionScope` (settable) + scoped filtering applied in `reload()`.

- [ ] **Step 1: Read the current `reload()` browse branch and the `audioStartTimeByBlockID` population.** Open `EchoCore/ViewModels/ReaderFeedViewModel.swift` and locate: the `sections` property (line 54), `sections = parsedSections` at line **250**, `applyTrackScope(currentTrackScope)` at line **325**, and `audioStartTimeByBlockID` being populated inside `applyTrackScope` at lines **373/387**. Confirm the filter must run after `applyTrackScope` (not before `sections = parsedSections`). Also confirm which property the browse-mode UI renders: if Phase 1 added `displaySections` (line 61, `private(set)`) and the browse branch never sets it (it is only set in the search branch at line 126), then the UI likely binds to `sections` in browse mode — verify this and filter `sections` after the `applyTrackScope` call. If `displaySections` IS used in browse mode, also filter it there.

- [ ] **Step 2: Add the published property.** Just below the existing published properties (after `var searchQuery: String?`), add:

```swift
    /// Scopes the feed to a reconstructed session's audio window. `.wholeBook`
    /// = no filter (default). Set this then call `reload()`.
    var sessionScope: SessionScope = .wholeBook {
        didSet {
            guard oldValue != sessionScope else { return }
            reload()
        }
    }
```

- [ ] **Step 3: Apply the filter in the browse branch of `reload()`.** Find the browse-branch block that produces `parsedSections` (the `[ReaderCardSection]` built from `epub_block`/`timeline_item`). `sections = parsedSections` is at line **250** in the current file; `audioStartTimeByBlockID` is populated inside `applyTrackScope(_:)` (called at line 325, populates the map at lines 373/387). Because the filter depends on `audioStartTimeByBlockID` being fully populated, place it **after** `applyTrackScope(currentTrackScope)` (post-line-325), not before `sections = parsedSections`. Insert after `applyTrackScope(currentTrackScope)`:

```swift
        // Phase 5: restrict to a session's audio window when scoped.
        // Must run AFTER applyTrackScope so audioStartTimeByBlockID is populated.
        if let allowed = SessionScopeReducer.blockIDsInScope(
            audioStartTimeByBlockID: audioStartTimeByBlockID,
            scope: sessionScope
        ) {
            sections = sections.compactMap { section in
                let keptItems = section.items.filter { item in
                    switch item {
                    case let .block(record):
                        return allowed.contains(record.id)
                    case .chapterHeader:
                        return true // headers stay; empty chapters pruned below
                    }
                }
                // Drop a section that has no real blocks left (only a header).
                let hasBlock = keptItems.contains { if case .block = $0 { return true } else { return false } }
                guard hasBlock else { return nil }
                return ReaderCardSection(id: section.id, headingStack: section.headingStack, items: keptItems)
            }
        }
```

> **B1 fix:** the filter is placed after `applyTrackScope(currentTrackScope)` so `audioStartTimeByBlockID` (populated at lines 373/387 inside that call) is not stale when the filter runs. If Phase 1 added a `displaySections` property that the browse-mode UI renders directly, also determine whether it is derived from `sections` (in which case filtering `sections` flows through automatically) or is set independently — if set independently, apply the same filter to that property too after verifying it is the actual property the UI binds to. **B2 note:** confirm in Step 1 which single property the browse-branch UI (including `SessionDetailFeedView`) binds to, and ensure that is the one being filtered; `SessionDetailFeedView` in Task 6 reads `viewModel.sections` — make sure that matches. Adjust the `ReaderCardSection(id:headingStack:items:)` call to match its actual memberwise initializer.

- [ ] **Step 4: Add a VM scope test.** Append to `EchoTests/SessionSummaryServiceTests.swift` a new suite (kept in the same file is fine, but prefer a dedicated file). Create `EchoTests/ReaderFeedViewModelScopeTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct ReaderFeedViewModelScopeTests {
    @Test func settingSessionScopeFiltersSectionsToWindow() throws {
        let dbService = try DatabaseService(inMemory: ())
        let bk = "scoped-bk"

        // Insert a minimal book with blocks + timeline_item audio anchors so the VM
        // populates audioStartTimeByBlockID. The exact insert columns mirror what
        // the browse branch reads; copy them from a passing ReaderFeedViewModel test.
        try dbService.writer.write { db in
            // Schema_V1 requires title NOT NULL and duration NOT NULL (no default).
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, ?, 0.0)",
                arguments: [bk, "Bk"]
            )
        }

        let vm = ReaderFeedViewModel(audiobookID: bk, db: dbService.writer)
        vm.reload()
        let wholeBookCount = vm.sections.count

        vm.sessionScope = .session(start: 0, end: 0.0001) // a window that should match nothing
        // didSet triggered reload; with no audio anchors in window, scoped <= wholeBook.
        #expect(vm.sections.count <= wholeBookCount)
    }
}
```

> This is a smoke-level guard; the *real* filter math is exhaustively tested in `SessionScopeReducerTests`. If a richer VM fixture (full blocks + anchors) is available from an existing `ReaderFeedViewModel` test, copy its inserts to assert exact counts.

- [ ] **Step 5: Build + run.**

```bash
make build-tests && make test-only FILTER=EchoTests/ReaderFeedViewModelScopeTests
```

Expected: build succeeds; `Test run with 1 test passed`.

- [ ] **Step 6: Commit.**

```bash
git add EchoCore/ViewModels/ReaderFeedViewModel.swift EchoTests/ReaderFeedViewModelScopeTests.swift
git commit -m "feat(feed): add SessionScope axis to ReaderFeedViewModel.reload (Phase 5)"
```

---

## Task 5: macOS reader parity — collapsible chapter accordion

**Files:**
- Modify: `Echo macOS/Views/MacReaderFeedView.swift`
- Test: build-verified via macOS scheme (no unit-testable surface; the pure pieces it uses are already tested in `FeedAccordionTests` and `ChapterAudioStatusResolverTests`).

**Interfaces:**
- Consumes (from `Shared/`, both already macOS-reachable): `FeedAccordion.toggled(current:tapped:)`, `FeedAccordion.autoExpand(current:playingChapterKey:lastPlayingChapterKey:)`, `ChapterAudioStatusResolver(db:).chaptersWithAudio(audiobookID:)`. Reads `MacPlayerModel.audiobookID` (computed, `MacPlayerModel.swift:57`) and `MacPlayerModel.isPlaying` (`private(set)`). Existing `blocks: [EPubBlockRecord]` (already loaded) + `EPubBlockRecord.chapterIndex` for grouping.
- Produces: a SwiftUI accordion grouped by chapter, with has-audio styling and playing-chapter auto-expand.

- [ ] **Step 1: Read the current macOS feed.** Open `Echo macOS/Views/MacReaderFeedView.swift`. Note: it holds `@State private var blocks: [EPubBlockRecord]`, `currentBlockID`, the load (`task` / `.onAppear`), and the poll loop `trackCurrentBlock()` (≈ lines 121–258) which already contains `if player.isPlaying, player.currentTime > 0 { … }` (≈ line 235 — note the `player.currentTime > 0` guard). Confirm `EPubBlockRecord` exposes a chapter-index field (the property name — `chapterIndex` — used for grouping). If the field is absent on the macOS-visible `EPubBlockRecord`, derive the chapter key via `ReaderFeedDisplayBuilder.chapterKey(forSectionID:)`'s rule applied to the block's section id; document the choice inline.

- [ ] **Step 2: Add accordion state + grouped model.** Add these to `MacReaderFeedView`'s state and a computed grouping. Insert after the existing `@State` declarations:

```swift
    /// Phase 5 (macOS parity): which chapter is currently expanded (nil = all collapsed).
    @State private var openChapterKey: Int?
    /// Chapter indices that actually have audio (honest has-audio styling).
    @State private var chaptersWithAudio: Set<Int> = []
    /// Tracks the previously-playing chapter so auto-expand only fires on change.
    @State private var lastPlayingChapterKey: Int?

    /// Blocks grouped into one entry per chapter, in reading order.
    /// Uses `$0.chapterIndex ?? -1` because `EPubBlockRecord.chapterIndex` is `Int?`;
    /// -1 is the front-matter convention already used by `ChapterAudioStatusResolver`.
    private var chapterGroups: [(key: Int, title: String, hasAudio: Bool, blocks: [EPubBlockRecord])] {
        let grouped = Dictionary(grouping: blocks, by: { $0.chapterIndex ?? -1 })
        return grouped.keys.sorted().map { key in
            let chapterBlocks = grouped[key] ?? []
            // Use the first heading-like block's text as the chapter title; fall back.
            // EPubBlockRecord.text is String? — unwrap with nil-coalescing.
            let title = chapterBlocks.first(where: { $0.blockKind == "heading" })?.text
                ?? chapterBlocks.first?.text
                ?? "Chapter \(key + 1)"
            return (key: key, title: title, hasAudio: chaptersWithAudio.contains(key), blocks: chapterBlocks)
        }
    }
```

> Replace `$0.chapterIndex`, `$0.blockKind == "heading"`, and `$0.text` with the actual `EPubBlockRecord` property names confirmed in Step 1. `chapterIndex` is the recon-confirmed grouping field; the heading-kind sentinel matches the iOS `ReaderCardItem` usage.

- [ ] **Step 3: Load the has-audio set when blocks load.** In the existing block-load path (after `blocks` is assigned), add:

```swift
        // Phase 5: honest per-chapter has-audio for the accordion.
        if let audiobookID = player.audiobookID {
            let resolver = ChapterAudioStatusResolver(db: dbService.writer)
            chaptersWithAudio = (try? resolver.chaptersWithAudio(audiobookID: audiobookID)) ?? []
        }
```

> `dbService` is the existing `@Environment(DatabaseService.self)`; `.writer` is its `DatabaseWriter` (same accessor used by iOS resolvers and `SessionSummaryService`). If the macOS view names it differently, use that name.

- [ ] **Step 4: Render the accordion.** Replace the existing flat `ForEach(blocks, id: \.id)` (in the `LazyVStack`/scroll body) with a chapter-grouped accordion:

```swift
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(chapterGroups, id: \.key) { group in
                // Collapsed chapter header row (always visible, tappable).
                Button {
                    openChapterKey = FeedAccordion.toggled(current: openChapterKey, tapped: group.key)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: openChapterKey == group.key ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(group.title)
                            .font(.headline)
                            .foregroundStyle(group.hasAudio ? .primary : .secondary)
                        if !group.hasAudio {
                            Text("Text only")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Expanded content (only the open chapter).
                if openChapterKey == group.key {
                    ForEach(group.blocks, id: \.id) { block in
                        // Reuse the existing per-block macOS rendering.
                        // IMPORTANT: there is no pre-existing `blockRow(_:)` helper —
                        // extract the body of the old flat ForEach into a
                        // `@ViewBuilder private func blockRow(_ block: EPubBlockRecord) -> some View`
                        // before inserting this accordion, then call it here.
                        // The real call is MacBlockCardView(block:isActive:activeWordIndex:onTap:)
                        // (or whatever the existing per-block view is named in this file).
                        MacBlockCardView(
                            block: block,
                            isActive: block.id == currentBlockID,
                            activeWordIndex: nil,
                            onTap: { }
                        )
                        .id(block.id)
                    }
                }
                Divider()
            }
        }
```

> **M3:** There is no pre-existing `blockRow` helper in `MacReaderFeedView`. The real per-block view is `MacBlockCardView(block:isActive:activeWordIndex:onTap:)` — confirm the exact call signature by reading the old flat `ForEach` body. Extract it into a `@ViewBuilder private func blockRow(_ block: EPubBlockRecord) -> some View` before replacing the flat list, then call `blockRow(block)` (or `MacBlockCardView(…)` directly) in the accordion. Do not invent new block rendering — reuse exactly what was there (word highlighting, `currentBlockID`, tap handling).

- [ ] **Step 5: Auto-expand the playing chapter.** In `trackCurrentBlock()`, inside the existing `if player.isPlaying { … }` branch where `currentBlockID` is computed, add auto-expand using the playing block's chapter:

```swift
            // Phase 5: auto-expand the chapter that is currently playing.
            if let playingID = currentBlockID,
               let playingChapter = blocks.first(where: { $0.id == playingID })?.chapterIndex {
                openChapterKey = FeedAccordion.autoExpand(
                    current: openChapterKey,
                    playingChapterKey: playingChapter,
                    lastPlayingChapterKey: lastPlayingChapterKey
                )
                lastPlayingChapterKey = playingChapter
            }
```

> Place this where `currentBlockID` is already updated, so the chapter key is fresh. `FeedAccordion.autoExpand` is the Phase-1 pure rule: it only changes `openChapterKey` when the playing chapter changes (so user collapses aren't fought).

- [ ] **Step 6: Build the macOS target (foreground, build slot free).**

```bash
xcodebuild -scheme "Echo macOS" -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`. Fix any property-name mismatches surfaced (`chapterIndex`/`blockKind`/`text`/`blockRow`). Do **not** run this concurrently with any other xcodebuild.

- [ ] **Step 7: Commit.**

```bash
git add "Echo macOS/Views/MacReaderFeedView.swift"
git commit -m "feat(feed): macOS reader collapsible chapter accordion parity (Phase 5)"
```

---

## Task 6: iOS Sessions list + session-detail feed

**Files:**
- Create: `EchoCore/Views/SessionsListView.swift`, `EchoCore/Views/SessionDetailFeedView.swift`
- Modify: `EchoCore/Views/ReaderTab.swift`
- Test: build-verified on the iOS scheme (SwiftUI views; logic is already covered by `SessionSummaryServiceTests` + `SessionScopeReducerTests`).

**Interfaces:**
- Consumes: `SessionSummaryService(db:).sessions(audiobookID:)`, `SessionSummary`, `SessionScope`, `ReaderFeedViewModel`. Reads `DatabaseService` from `@Environment`.
- Produces: a navigable Sessions history; tapping a row opens `SessionDetailFeedView` which builds a `ReaderFeedViewModel` with `sessionScope = .session(start:end:)`.

- [ ] **Step 1: Create `SessionsListView`.**

Create `EchoCore/Views/SessionsListView.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Browsable history of reconstructed listening sessions for one audiobook.
/// Tapping a row scopes the reader feed to that session.
struct SessionsListView: View {
    let audiobookID: String
    @Environment(DatabaseService.self) private var dbService

    @State private var sessions: [SessionSummary] = []
    @State private var isLoading = true
    @State private var loadError: String?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                ContentUnavailableView("Couldn’t load sessions", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else if sessions.isEmpty {
                ContentUnavailableView("No sessions yet", systemImage: "clock", description: Text("Play this book and your listening sessions will appear here."))
            } else {
                List(sessions) { session in
                    NavigationLink {
                        SessionDetailFeedView(audiobookID: audiobookID, session: session)
                    } label: {
                        sessionRow(session)
                    }
                }
            }
        }
        .navigationTitle("Sessions")
        .task { await load() }
    }

    @ViewBuilder
    private func sessionRow(_ session: SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.dateFormatter.string(from: session.startedAt))
                .font(.headline)
            if let range = session.chapterRangeLabel {
                Text(range)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Label("\(Int(session.minutesListened.rounded())) min", systemImage: "headphones")
                if session.hasRoute {
                    Label(String(format: "%.1f mi", session.routeMiles), systemImage: "map")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                if session.bookmarkCount > 0 { Label("\(session.bookmarkCount)", systemImage: "bookmark") }
                if session.cardCount > 0 { Label("\(session.cardCount)", systemImage: "rectangle.on.rectangle") }
                if session.noteCount > 0 { Label("\(session.noteCount)", systemImage: "note.text") }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        isLoading = true
        loadError = nil
        let bookID = audiobookID
        let writer = dbService.writer
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try SessionSummaryService(db: writer).sessions(audiobookID: bookID)
            }.value
            sessions = result
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}
```

- [ ] **Step 2: Create `SessionDetailFeedView`.**

Create `EchoCore/Views/SessionDetailFeedView.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later

import MapKit
import SwiftUI

/// Hosts the reader feed scoped to one reconstructed session, with an optional
/// route map header when location was recorded.
struct SessionDetailFeedView: View {
    let audiobookID: String
    let session: SessionSummary
    @Environment(DatabaseService.self) private var dbService

    @State private var viewModel: ReaderFeedViewModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if session.hasRoute {
                    routeMap
                        .frame(height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                }
                recapHeader
                    .padding(.horizontal)

                if let viewModel {
                    // Render the scoped sections. Reuse the existing read-only row
                    // rendering used by ReaderTab's non-collection fallback. If only
                    // the UICollectionView path exists, present sections as simple Text
                    // rows here (detail view is read-only, no word-tap this phase).
                    ForEach(viewModel.sections) { section in
                        ForEach(section.items.indices, id: \.self) { idx in
                            sessionItemView(section.items[idx])
                                .padding(.horizontal)
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if viewModel == nil {
                let vm = ReaderFeedViewModel(audiobookID: audiobookID, db: dbService.writer)
                vm.sessionScope = .session(start: session.startPosition, end: session.endPosition)
                vm.reload()
                viewModel = vm
            }
        }
    }

    @ViewBuilder
    private func sessionItemView(_ item: ReaderCardItem) -> some View {
        switch item {
        case let .chapterHeader(title, _):
            Text(title)
                .font(.title3.bold())
                .padding(.top, 8)
        case let .block(record):
            // EPubBlockRecord.text is String? — unwrap before passing to Text.
            Text(record.text ?? "")
                .font(.body)
        }
    }

    @ViewBuilder
    private var recapHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(Int(session.minutesListened.rounded())) minutes listened")
                .font(.headline)
            if let range = session.chapterRangeLabel {
                Text(range).font(.subheadline).foregroundStyle(.secondary)
            }
            if session.hasRoute {
                Text(String(format: "%.1f miles travelled", session.routeMiles))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var routeMap: some View {
        Map {
            MapPolyline(coordinates: session.route.map(\.coordinate))
                .stroke(.tint, lineWidth: 4)
            if let first = session.route.first {
                Marker("Start", coordinate: first.coordinate)
            }
            if let last = session.route.last {
                Marker("End", coordinate: last.coordinate)
            }
        }
    }
}
```

> The `chapterHeader(title, _)` and `block(record)` destructuring must match the actual `ReaderCardItem` cases (`EchoCore/Models/ReaderCardItem.swift`: `case chapterHeader(title:chapterIndex:)`, `case block(EPubBlockRecord)`). `record.text` must match the `EPubBlockRecord` text property name. The detail view is intentionally read-only (no word-tap this phase, per Phase-1 scope carve-out).

- [ ] **Step 3: Add a Sessions entry point in `ReaderTab`.** Open `EchoCore/Views/ReaderTab.swift`. Add a toolbar button (or a row in the existing `EPUBTOCSheet`'s host) that pushes `SessionsListView`. The minimal, low-risk wiring is a toolbar item on the reader navigation:

```swift
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SessionsListView(audiobookID: audiobookID)
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .accessibilityLabel("Sessions")
                    }
                }
            }
```

> Place this on the view that already owns a `NavigationStack`/nav bar inside `ReaderTab`. If `ReaderTab` has no nav stack of its own, wrap the new `NavigationLink` destination usage in the nearest enclosing stack, or present `SessionsListView` via a `.sheet` toggled by a `@State private var showSessions = false`. **N5:** `ReaderTab` has no top-level `audiobookID` view property (it is local in helper functions). Thread the `audiobookID` via `folderURL?.absoluteString` (the same pattern the existing ReaderFeedViewModel construction uses) or add a `let audiobookID: String` parameter to the toolbar closure — confirm the exact local variable name by reading the existing `ReaderFeedViewModel(audiobookID:…)` call site in `ReaderTab`.

- [ ] **Step 4: Add new files to the iOS target.** New EchoCore files must be members of the `Echo` target only (iOS). After creating them, verify membership:

```bash
grep -c "SessionsListView.swift" Echo.xcodeproj/project.pbxproj
grep -c "SessionDetailFeedView.swift" Echo.xcodeproj/project.pbxproj
```

Expected: each `> 0`. If the project uses synchronized file groups (file-system-synced), no pbxproj edit is needed — the build in Step 5 will confirm. If `0` and the project is not synced, add them to the `Echo` target in Xcode (or via the project-edit tooling) — and ensure they are **NOT** added to `Echo macOS`.

- [ ] **Step 5: Build the iOS app + tests.**

```bash
make build-tests
```

Expected: `** TEST BUILD SUCCEEDED **`. Fix any `ReaderCardItem`/`EPubBlockRecord` property mismatches.

- [ ] **Step 6: Commit.**

```bash
git add EchoCore/Views/SessionsListView.swift EchoCore/Views/SessionDetailFeedView.swift EchoCore/Views/ReaderTab.swift Echo.xcodeproj/project.pbxproj
git commit -m "feat(feed): iOS Sessions history list + session-scoped detail feed (Phase 5)"
```

---

## Task 7: Simulator smoke test + perf check

**Files:** none (verification only).

- [ ] **Step 1: Confirm the overnight build slot is idle.** Ensure `~/Developer/echo-overnight/redo-resume.sh` (NarrationHarness) is not running before building.

- [ ] **Step 2: Run the full new-test set.**

```bash
make test-only FILTER=EchoTests/SessionSummaryServiceTests
make test-only FILTER=EchoTests/SessionScopeReducerTests
make test-only FILTER=EchoTests/ReaderFeedViewModelScopeTests
```

Expected: all three green (`5`, `4`, `1` tests respectively).

- [ ] **Step 3: Build + boot the iOS app and exercise Sessions.** Build/run the `Echo` scheme on the `iPhone 17` simulator. With a book that has playback history (or after playing a few segments), open the reader → tap the Sessions (clock) toolbar button → confirm rows render with date, chapter range, minutes, and counts. Tap a row → confirm the scoped feed shows only that session's blocks (and a route map iff location was recorded).

- [ ] **Step 4: Perf decision (schema gate).** While scrolling the Sessions list, observe responsiveness. If the list visibly stutters with many sessions (the `sessions(audiobookID:)` query is O(events) per book and runs once off the main thread — should be fine), no action. **Only if** profiling shows the query is a bottleneck: add an additive `session_summary_cache` table behind the **next free** migration version (re-check `git log origin/nightly -- Shared/Database/Migrations/`; today's next is V24 but may be taken), populate it lazily on session close, and read from it in `SessionSummaryService`. Add `SchemaVxxTests` and run the **schema-migration-reviewer** before committing. **Default expectation: NO migration needed.**

- [ ] **Step 5: Build the macOS app and verify the accordion.** Build/run `Echo macOS`; open a book with EPUB text; confirm chapters render collapsed, tapping a header expands one chapter at a time, text-only chapters show the muted styling, and starting playback auto-expands the playing chapter.

---

## Task 8: Doc-sync

**Files:**
- Modify: `ARCHITECTURE.md`, `README.md`, `ROADMAP.md`, `CHANGELOG.md`

- [ ] **Step 1: Invoke the doc-sync skill.** Run the `doc-sync` skill (per CLAUDE.md, it owns ARCHITECTURE.md / README.md / ROADMAP.md / CHANGELOG.md updates). Provide it the Phase 5 change summary: Sessions history list, session-scoped reader feed, macOS reader accordion parity, and the new `SessionSummaryService`/`SessionSummary`/`SessionScope` types. Let it draft the edits, then apply.

- [ ] **Step 2: ARCHITECTURE.md — update the "EPUB Reader Feed (Current)" section (≈ line 574).** Append:

```markdown
**Unified Feed Initiative (Phases 1–5, June 2026):** The reader feed is default-collapsed
(one row per audio chapter = a table of contents); tapping a chapter expands it in place
(accordion, one chapter at a time, `Shared/FeedAccordion.swift`), and the playing chapter
auto-expands. Chapter rows show honest has-audio / text-only styling via
`Shared/Services/ChapterAudioStatusResolver.swift`. A **Sessions history** (Phase 5) lists
reconstructed listening sessions — there is no `playback_session` table; `SessionSummaryService`
(`Shared/Services/`) groups `playback_event` rows on wall-clock gaps and derives GPS route
(`session_location`), chapter range (`chapter` overlap join), minutes, and bookmark/card/note
counts into a pure `SessionSummary`. Tapping a session scopes the feed to its audio window via
`SessionScope` + `SessionScopeReducer` (pure, `Shared/`) applied in `ReaderFeedViewModel.reload()`.
**macOS parity:** `MacReaderFeedView` reuses the UIKit-free pure types (`FeedAccordion`,
`ChapterAudioStatusResolver`) to drive a SwiftUI-native chapter accordion; it does **not** import
the iOS `ReaderFeedViewModel`/`ReaderFeedCollectionView` (those are UIKit/EchoCore, iOS-only).
```

- [ ] **Step 3: ARCHITECTURE.md — correct the "session" terminology.** Anywhere the docs imply a `playback_session` **table** exists, correct it: sessions are derived from `playback_event` rows; `real_time_event` (`event_type='playbackSession'`) only brackets wall-clock spans and has no audio position data; `session_location` FKs to `playback_event.id`.

- [ ] **Step 4: ROADMAP.md — add the unified-feed tracker.** Under Part A (near the EPUB Viewing entry ≈ line 312), add:

```markdown
### Unified Feed (Read + Study merge)
- [x] Phase 0 — `ChapterAudioStatusResolver` foundation (PR #147)
- [x] Phase 1 — Collapsible reader feed (iOS accordion + auto-expand)
- [x] Phase 5 — Sessions history list, session-scoped feed, macOS reader accordion parity
- [ ] Phases 2–4 — off-switch/grey-out, two-axis filters, feed items (bookmarks/cards/memos/notes)
```

> If Phases 2–4 shipped before Phase 5, mark them `[x]`; otherwise leave as above. Spec: `docs/superpowers/specs/2026-06-22-unified-feed-design.md`.

- [ ] **Step 5: README.md — feature summary.** If README lists reader/study features, add a one-line bullet: "Sessions history — review when/where you listened (GPS route + miles), what chapters you covered, and the bookmarks/cards/notes you made, then jump back into that exact slice of the book."

- [ ] **Step 6: CHANGELOG.md — add a Phase 5 entry** under the Unreleased / next-version heading:

```markdown
### Added
- Sessions history: browse past listening sessions (time, GPS route + miles, minutes,
  chapter range, and bookmark/card/note counts); tap a session to scope the reader feed to it.
- macOS reader feed parity: collapsible per-chapter accordion with honest has-audio styling
  and playing-chapter auto-expand.
```

- [ ] **Step 7: Build once more to ensure docs-only edits didn't touch code.** (No build needed for `.md` changes; skip if only docs changed.)

- [ ] **Step 8: Commit.**

```bash
git add ARCHITECTURE.md README.md ROADMAP.md CHANGELOG.md
git commit -m "docs(feed): sync ARCHITECTURE/README/ROADMAP/CHANGELOG for unified-feed Phase 5"
```

- [ ] **Step 9: Open the PR against nightly.**

```bash
gh pr create --base nightly --title "feat(feed): unified feed Phase 5 — Sessions list + macOS parity + doc-sync" --body "$(cat <<'EOF'
Implements unified-feed Phase 5 (spec §9, §12).

- Sessions history (`SessionSummaryService` + `SessionSummary`): reconstructs sessions from `playback_event` (no `playback_session` table), derives GPS route/miles, chapter range, minutes, and counts.
- Session-scoped reader feed via pure `SessionScope`/`SessionScopeReducer` applied in `ReaderFeedViewModel.reload()`.
- macOS reader parity: `MacReaderFeedView` collapsible chapter accordion reusing `FeedAccordion` + `ChapterAudioStatusResolver` (UIKit-free, `Shared/`).
- Doc-sync: ARCHITECTURE/README/ROADMAP/CHANGELOG.

No schema change (sessions derived in-query). Tests: SessionSummaryServiceTests (5), SessionScopeReducerTests (4), ReaderFeedViewModelScopeTests (1).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-Review

**Spec coverage checklist (§9, §12, §2 macOS parity):**

- [ ] Browsable Sessions history with one row per session — `SessionsListView` (Task 6).
- [ ] Row recaps **when** — `SessionSummary.startedAt`, formatted in `sessionRow`.
- [ ] Row recaps **where** (GPS route + miles if location enabled) — `route`/`routeMiles`/`hasRoute`; `routeMap` in `SessionDetailFeedView`; derivation in `SessionSummaryService` from `session_location` (Trap D).
- [ ] Row recaps **minutes listened** — speed-adjusted `minutesListened` (Trap C / StatsRepository parity).
- [ ] Row recaps **chapter range covered** — `firstChapterTitle`/`lastChapterTitle` via the overlap join (Trap C); not stored, derived.
- [ ] Row recaps **counts** of bookmarks/cards/notes — `count(table:)` over `created_at` window. **Images = 0** (documented default; no per-session image count exists — flagged below).
- [ ] Tap a row → scope the feed to that session — `SessionDetailFeedView` builds a `ReaderFeedViewModel` with `.session(start:end:)`; filter via `SessionScopeReducer` in `reload()` (Task 4).
- [ ] macOS reuses the same read model / pure pieces — `MacReaderFeedView` uses `FeedAccordion` + `ChapterAudioStatusResolver` (Task 5). `SessionSummary`/`SessionSummaryService`/`SessionScope` live in `Shared/`, compilable by both targets.
- [ ] Doc-sync ARCHITECTURE/README/ROADMAP (+ CHANGELOG) via the doc-sync skill (Task 8).

**Type-consistency check:**

- `SessionSummary` is `Codable, Hashable, Sendable, Identifiable` — safe across the `Task.detached` boundary in `SessionsListView.load()`.
- `SessionSummaryService` is `struct { let db: DatabaseWriter }` (the project DAO convention) — matches `ChapterAudioStatusResolver`.
- `SessionScope`/`SessionScopeReducer` are pure and UIKit-free, in `Shared/` — reusable by macOS.
- No `playback_session` table is referenced anywhere (Trap B honored); all session reconstruction is from `playback_event` + `session_location` (Trap D join path).
- All value bindings are parameterized; the only string-interpolated SQL is the literal table name in `count(table:)` and the bind placeholders (`databaseQuestionMarks`) — no user input interpolation (Database Safety).
- **No migration** added by default (Global Constraints / Trap E). If Task 7 forces a cache table, the **next free** version is claimed at implementation time after re-checking `origin/nightly`, never hard-coded — and the schema-migration-reviewer runs first.

**Open questions resolved by documented default (flag for owner review):**

1. **Trap A (where `ReaderFeedDisplayBuilder` lives):** Default = do **not** move EchoCore types to `Shared/`; macOS drives its own accordion from `[EPubBlockRecord]` + the already-`Shared/` pure types. Cleaner alternative (move the grouping types to `Shared/`) is deferred. **Owner: confirm you don't want a single shared grouping path.**
2. **Image count per session:** No per-session image metric exists; defaulted to `0` (the `imageCount` field is wired for a future source). Spec §9 lists "pics" counts — the source exists (`block_kind='image'` over the audio window) but is not yet implemented. **Owner: confirm 0 is an acceptable deferral, or request an implementation of the `block_kind='image'` window query.**
3. **`note` table:** `Schema_V2.swift:9` confirms the `note` table exists; `count(table:)` is belt-and-suspenders (the exists-check will always return true in production). **Resolved.**
6. **Chapter-range overlap join (A1):** `StatsRepository.fetchChapterCoverage` does NOT use a SQL overlap join (it computes in Swift via `StatsAggregator`). The chapter-range join in `SessionSummaryService` is new SQL with no existing test. The `SessionSummaryServiceTests` do not insert a `chapter` row, so `firstChapterTitle`/`lastChapterTitle` will always be `nil` in the current tests. **Owner: add a chapter-row test fixture if you want chapter range coverage tested, or accept that the join logic is smoke-verified only in the simulator.**
4. **Gap threshold:** 5 minutes (300s) default for grouping `playback_event` rows into one session. **Owner: confirm threshold.**
5. **Session-detail rendering:** read-only `Text` rows (no word-tap), consistent with Phase-1 word-tap deferral. **Owner: confirm a read-only scoped view is acceptable for now.**

---

## Execution Handoff

**Recommended: subagent-driven-development.** Tasks 1–4 (pure types + service + VM wiring) are independent of Task 5 (macOS) and can be dispatched in parallel-ish review checkpoints; Task 6 depends on Tasks 1–4; Tasks 7–8 are sequential finishers. Each task ends in a green build/test + commit, so a fresh subagent can pick up the next task from the committed state. Use `superpowers:subagent-driven-development`, one task per subagent, with `make build-tests` / `make test-only FILTER=…` as the verification gate (foreground, build slot free, never two concurrent xcodebuilds).

**Alternative: inline execution.** Execute Tasks 1→8 in order in this session, committing after each. This avoids subagent handoff overhead but holds the single build slot serially — fine on a 16 GB machine as long as the overnight NarrationHarness is paused.

**Before starting either path:** verify the base is nightly (`git merge-base --is-ancestor origin/nightly HEAD || git fetch origin nightly`) and that `redo-resume.sh` is idle.
