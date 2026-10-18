# On-Device Library — UI Milestone 4 (Facets · Status · Roots · Missing-File · Restore) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **DEPENDENCY: this plan executes AFTER M3 lands.** It consumes M3's `LibraryView`, `LibraryViewModel`, the `SecurityScopeManager.libraryRoot` slot, and `PlayerModel.openLibraryBook` (see `docs/superpowers/plans/2026-06-27-local-library-ui-m3.md`), plus M1/M2's `LibraryService` / `LibraryRootDAO` / `LibraryOpenTarget`. Where this plan references those symbols, they are defined by M3/M1/M2, not re-created here.

**Goal:** Complete the Library into a full browsing + management surface — drill-down facet browsing with processing-status dots, a fast single-pass status query, Manage Roots (rescan/remove), graceful missing-file handling (hide / show / relocate / remove), and restore-on-relaunch for library books — then retire `FirstRunLandingView` and bring the Library to macOS.

**Architecture:** Extend `LibraryViewModel` with facet drill-down state and a batched status map; add a `LibraryStatusDAO`-style single-pass query to `LibraryService` (kills the M1/M2 N+1 `// FIXME(M3)`); add `ManageRootsView` + a `LibraryRootViewModel`; add availability/relocate to `LibraryService`; persist a "last library book" pointer for smart-landing restore.

**Tech Stack:** Swift 6, SwiftUI, GRDB, os.Logger. UI verified on the simulator (UI tests excluded from the scheme); logic is unit-tested against `DatabaseService(inMemory:)`.

## Global Constraints

- **SPDX header** line 1 of every Swift file: `// SPDX-License-Identifier: GPL-3.0-or-later`.
- **No protocols** for new services/VMs — concrete types, constructor/closure injection.
- **Logging** via `Logger(category:)`; no `print()` in production.
- **Swift 6 strict concurrency:** `@MainActor` view models/views; no `??` with an `await` RHS.
- **Build/test:** `make build-tests CODE_SIGNING_ALLOWED=NO`, then `make test-only FILTER=EchoTests/<Suite>`. `CODE_SIGNING_ALLOWED=NO` mandatory. **16 GB gate:** prefix `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && <build>` when blocked; never run two builds at once; retry once on apparent external interference.
- **Toolchain:** `try #require(...)` emits an unavoidable spurious warning — don't "fix" it.
- **UI verification:** views verified by building + launching on the simulator; TDD only logic.
- **Reuse:** `LibraryService` (M1/M2), `LibraryViewModel` (M3), `ArtworkCache`. Do not duplicate.

---

## File Structure

**New files**
- `EchoCore/Views/Library/LibraryBrowseByView.swift` — the "Browse by…" facet menu (Authors / Topics / Folders / Study / Processing) → filtered shelf.
- `EchoCore/Views/Library/LibraryStatusDot.swift` — the processing-status dot rendered on a cover.
- `EchoCore/Views/Library/ManageRootsView.swift` — list roots, rescan, remove; "Show unavailable" lives here.
- `EchoCore/ViewModels/LibraryRootsViewModel.swift` — roots list + rescan/remove/relocate state.

**Modified files**
- `EchoCore/Services/Library/LibraryService.swift` — add a single-pass `statusMap()` (study + processing for all books in one query pass), `availabilityCheck()`/`markUnavailable`, `relocateRoot`, `removeRoot(forgetBooks:)`.
- `EchoCore/ViewModels/LibraryViewModel.swift` — facet drill-down state; consume `statusMap`; `showUnavailable` wired to the shelf.
- `EchoCore/Views/Library/LibraryView.swift` — add the "Browse by…" entry + status dots; honor `showUnavailable`.
- `EchoCore/Views/Library/LibraryCoverCell.swift` — overlay the status dot.
- `EchoCore/ViewModels/PlayerModel.swift` — persist/restore a "last library book" pointer (`openLibraryBook` records it; `restoreLastSelectionIfPossible` consults it).
- `EchoCore/Services/Persistence.swift` — store the last-library-book pointer (id + root id) alongside the existing bookmark.

**Tests**
- `EchoTests/LibraryStatusMapTests.swift`, `EchoTests/LibraryRootsViewModelTests.swift`, `EchoTests/LibraryAvailabilityTests.swift`, `EchoTests/LibraryLastBookRestoreTests.swift`

---

## Task 1: `LibraryService.statusMap()` — single-pass study+processing status (kills the N+1)

**Files:**
- Modify: `EchoCore/Services/Library/LibraryService.swift`
- Test: `EchoTests/LibraryStatusMapTests.swift`

**Interfaces:**
- Consumes: M1/M2 `StudyStatus`, `ProcessingStatus`, the `playback_state`/`track`/`transcription_segment`/`alignment_anchor` tables.
- Produces: `struct LibraryBookStatus: Equatable { var study: StudyStatus; var processing: ProcessingStatus }` and `func statusMap(for bookIDs: [String]) throws -> [String: LibraryBookStatus]` — computes both statuses for many books with a bounded number of aggregate queries (NOT one-per-book). This replaces the per-book `studyStatus`/`processingStatus` calls in the section bucketing (the M1/M2 `// FIXME(M3)` N+1).

- [ ] **Step 1: Write the failing test**

Create `EchoTests/LibraryStatusMapTests.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct LibraryStatusMapTests {
    @Test func statusMapComputesStudyAndProcessingForManyBooks() throws {
        let db = try DatabaseService(inMemory: ())
        try db.writer.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration) VALUES ('a','A',100)")
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration) VALUES ('b','B',100)")
            // a: in-progress + narrated
            try db.execute(sql: "INSERT INTO playback_state (audiobook_id, last_position) VALUES ('a', 50)")
            try db.execute(sql: """
                INSERT INTO track (id, audiobook_id, title, duration, file_path, sort_order, narration_voice)
                VALUES ('t1','a','c1',50,'/a/c1.wav',0,'af_heart')
                """)
            // b: finished + transcribed
            try db.execute(sql: "INSERT INTO playback_state (audiobook_id, last_position) VALUES ('b', 99)")
            try db.execute(sql: """
                INSERT INTO transcription_segment (audiobook_id, start_time, end_time, text)
                VALUES ('b', 0, 1, 'hi')
                """)
        }
        let service = LibraryService(db: db)
        let map = try service.statusMap(for: ["a", "b"])
        #expect(map["a"]?.study == .inProgress)
        #expect(map["a"]?.processing.contains(.narrated) == true)
        #expect(map["b"]?.study == .finished)
        #expect(map["b"]?.processing.contains(.transcribed) == true)
    }
}
```

- [ ] **Step 2: Run, verify it fails**

Run: `make build-tests CODE_SIGNING_ALLOWED=NO && make test-only FILTER=EchoTests/LibraryStatusMapTests`
Expected: FAIL — `LibraryService has no member 'statusMap'`.

- [ ] **Step 3: Implement `statusMap`** — one aggregate query per dimension (4 reads total, not 4×N)

Add to `LibraryService`:
```swift
struct LibraryBookStatus: Equatable {
    var study: StudyStatus
    var processing: ProcessingStatus
}

/// Study + processing status for many books in a bounded number of queries
/// (one aggregate read per dimension), replacing the per-book N+1.
func statusMap(for bookIDs: [String]) throws -> [String: LibraryBookStatus] {
    guard !bookIDs.isEmpty else { return [:] }
    return try db.writer.read { db -> [String: LibraryBookStatus] in
        // last_position per book + duration (study)
        let positions = try Row.fetchAll(db, sql: """
            SELECT a.id AS id, a.duration AS duration, ps.last_position AS pos
            FROM audiobook a
            LEFT JOIN playback_state ps ON ps.audiobook_id = a.id
            WHERE a.id IN \(sqlIn(bookIDs))
            """, arguments: StatementArguments(bookIDs))
        // narrated, transcribed, aligned counts per book
        let narrated = try idsWithRows(db, table: "track", bookIDs: bookIDs,
            extra: "AND narration_voice IS NOT NULL")
        let transcribed = try idsWithRows(db, table: "transcription_segment", bookIDs: bookIDs)
        let alignedCounts = try counts(db, table: "alignment_anchor", bookIDs: bookIDs)

        var result: [String: LibraryBookStatus] = [:]
        for row in positions {
            let id: String = row["id"]
            let duration: Double = row["duration"] ?? 0
            let pos: Double? = row["pos"]
            let study: StudyStatus = {
                guard let p = pos, p > 0 else { return .notStarted }
                if duration > 0, p >= duration * 0.98 { return .finished }
                return .inProgress
            }()
            var processing: ProcessingStatus = []
            if (alignedCounts[id] ?? 0) > 2 { processing.insert(.aligned) }
            if narrated.contains(id) { processing.insert(.narrated) }
            if transcribed.contains(id) { processing.insert(.transcribed) }
            result[id] = LibraryBookStatus(study: study, processing: processing)
        }
        return result
    }
}

private func sqlIn(_ ids: [String]) -> String {
    "(" + Array(repeating: "?", count: ids.count).joined(separator: ",") + ")"
}

private func idsWithRows(_ db: Database, table: String, bookIDs: [String], extra: String = "") throws -> Set<String> {
    let rows = try Row.fetchAll(db, sql:
        "SELECT DISTINCT audiobook_id AS id FROM \(table) WHERE audiobook_id IN \(sqlIn(bookIDs)) \(extra)",
        arguments: StatementArguments(bookIDs))
    return Set(rows.map { $0["id"] as String })
}

private func counts(_ db: Database, table: String, bookIDs: [String]) throws -> [String: Int] {
    let rows = try Row.fetchAll(db, sql:
        "SELECT audiobook_id AS id, COUNT(*) AS n FROM \(table) WHERE audiobook_id IN \(sqlIn(bookIDs)) GROUP BY audiobook_id",
        arguments: StatementArguments(bookIDs))
    return Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] as String, $0["n"] as Int) })
}
```
Then change `studyStatusSections`/`processingStatusSections` to call `statusMap(for: books.map(\.id))` ONCE and bucket from the map (instead of calling `studyStatus`/`processingStatus` per book). Remove the per-book `// FIXME(M3)` N+1 marker.

> **Confirm at implementation:** the table-name interpolation in the helpers is safe (literal table names, parameterized ids). Keep the `?`-placeholder argument binding for ids — never interpolate ids.

- [ ] **Step 4: Run, verify it passes** → `make test-only FILTER=EchoTests/LibraryStatusMapTests` PASS. Re-run `EchoTests/LibraryServiceTests` to confirm the section bucketing still passes via the new map.

- [ ] **Step 5: Commit**
```bash
git add EchoCore/Services/Library/LibraryService.swift EchoTests/LibraryStatusMapTests.swift
git commit -m "perf(library): single-pass statusMap replaces per-book N+1 (resolves M3 FIXME)"
```

---

## Task 2: Processing-status dot on covers + `LibraryViewModel` status wiring

**Files:**
- Create: `EchoCore/Views/Library/LibraryStatusDot.swift`
- Modify: `EchoCore/ViewModels/LibraryViewModel.swift`, `EchoCore/Views/Library/LibraryCoverCell.swift`

**Interfaces:**
- Consumes: `LibraryService.statusMap` (Task 1).
- Produces: `LibraryViewModel.statusMap: [String: LibraryService.LibraryBookStatus]` (populated in `reload()`); `LibraryStatusDot(processing:)` rendering the highest-value dot (green aligned → blue narrated → amber transcribed → grey none); `LibraryCoverCell` overlays it.

- [ ] **Step 1: `LibraryStatusDot.swift`**
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct LibraryStatusDot: View {
    let processing: LibraryService.ProcessingStatus

    private var color: Color {
        if processing.contains(.aligned) { return .green }
        if processing.contains(.narrated) { return .blue }
        if processing.contains(.transcribed) { return .orange }
        return .gray
    }
    private var label: String {
        if processing.contains(.aligned) { return "Aligned" }
        if processing.contains(.narrated) { return "Narrated" }
        if processing.contains(.transcribed) { return "Transcribed" }
        return "Not processed"
    }

    var body: some View {
        Circle().fill(color).frame(width: 10, height: 10)
            .overlay(Circle().stroke(.background, lineWidth: 1.5))
            .accessibilityLabel(Text(label))
    }
}
```

- [ ] **Step 2: Populate `statusMap` in `LibraryViewModel.reload()`** — after loading `sections`, compute `statusMap = (try? service.statusMap(for: sections.flatMap(\.books).map(\.id))) ?? [:]`. Add the stored property `var statusMap: [String: LibraryService.LibraryBookStatus] = [:]`.

- [ ] **Step 3: Overlay the dot in `LibraryCoverCell`** — add a `processing: LibraryService.ProcessingStatus` parameter and overlay `LibraryStatusDot(processing:)` at the cover's bottom-trailing. Pass it from `LibraryShelfGrid` (which gets the `statusMap` from the view model).

- [ ] **Step 4: Build + sim-verify** dots render on covers matching each book's state.

- [ ] **Step 5: Commit**
```bash
git add EchoCore/Views/Library/LibraryStatusDot.swift EchoCore/Views/Library/LibraryCoverCell.swift EchoCore/Views/Library/LibraryShelfGrid.swift EchoCore/ViewModels/LibraryViewModel.swift
git commit -m "feat(library): processing-status dots on shelf covers"
```

---

## Task 3: "Browse by…" facet drill-down

**Files:**
- Create: `EchoCore/Views/Library/LibraryBrowseByView.swift`
- Modify: `EchoCore/ViewModels/LibraryViewModel.swift`, `EchoCore/Views/Library/LibraryView.swift`

**Interfaces:**
- Consumes: `LibraryService.sections(by:)` for all axes (`.author`, `.topic`, `.folder`, `.studyStatus`, `.processingStatus`).
- Produces: a "Browse by…" toolbar menu in `LibraryView` that sets `vm.selectedAxis` and reloads; the shelf re-groups in place (it already renders `sections`). For the value-list drill-down style (Authors → that author's books), `LibraryBrowseByView` lists the section titles (`sections.map(\.title)`) as `NavigationLink`s to a single-section shelf.

- [ ] **Step 1: Add axis-cycling to `LibraryViewModel`** — `func selectAxis(_ axis: LibraryService.LibraryAxis)` sets `selectedAxis` + `reload()`. (Pure mapping; covered indirectly by the existing `reloadLoadsAvailableBooksForAxis` test pattern — add one asserting `.author` grouping.)

- [ ] **Step 2: `LibraryBrowseByView.swift`** — a `List` of the five axes; tapping one calls `vm.selectAxis(...)` and dismisses, OR (richer) navigates to a value list. Full code: a `Menu`/`List` with the five `LibraryAxis` cases and their display labels.

- [ ] **Step 3: Wire into `LibraryView`** — add a "Browse by…" `Menu` to the toolbar (alongside "Add Folder") presenting the five axes; selecting re-groups the shelf.

- [ ] **Step 4: Build + sim-verify** switching axes re-sections the shelf (Author groups, Topic groups, Folder groups, the two status groupings).

- [ ] **Step 5: Commit**
```bash
git add EchoCore/Views/Library/LibraryBrowseByView.swift EchoCore/Views/Library/LibraryView.swift EchoCore/ViewModels/LibraryViewModel.swift EchoTests/LibraryViewModelTests.swift
git commit -m "feat(library): Browse by… facet drill-down (author/topic/folder/status)"
```

---

## Task 4: Availability + relocate/remove on `LibraryService`

**Files:**
- Modify: `EchoCore/Services/Library/LibraryService.swift`
- Test: `EchoTests/LibraryAvailabilityTests.swift`

**Interfaces:**
- Produces:
  - `func relocateRoot(rootID: String, to newURL: URL) throws` — re-bookmark a moved root (`LibraryAccess.makeBookmark(newURL)` → update `library_root.bookmark`), then a rescan re-marks its books available.
  - `func removeRoot(rootID: String, forgetBooks: Bool) throws` — delete the `library_root`; if `forgetBooks`, delete its `audiobook` rows (and cascading study data); else clear their `source_root_id` (they become standalone but unavailable until relocated).
  - `func markUnavailableUnderMissingRoot(rootID: String) throws` — set `is_available = 0` for a root whose bookmark won't resolve.

- [ ] **Step 1: Write the failing test**

Create `EchoTests/LibraryAvailabilityTests.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct LibraryAvailabilityTests {
    private func fixedNow() -> String { "2026-06-27T00:00:00Z" }

    @Test func removeRootForgetBooksDeletesRows() throws {
        let db = try DatabaseService(inMemory: ())
        let service = LibraryService(db: db)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("avail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = try service.registerRoot(url: tmp, now: fixedNow)
        try AudiobookDAO(db: db.writer).save(AudiobookRecord(
            id: "bk", title: "T", author: nil, duration: 0, fileCount: nil,
            addedAt: fixedNow(), isAvailable: true, sourceRootID: root.id))

        try service.removeRoot(rootID: root.id, forgetBooks: true)
        #expect(try AudiobookDAO(db: db.writer).get("bk") == nil)
        #expect(try LibraryRootDAO(db: db.writer).get(root.id) == nil)
    }

    @Test func removeRootKeepBooksClearsSourceRoot() throws {
        let db = try DatabaseService(inMemory: ())
        let service = LibraryService(db: db)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("avail2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = try service.registerRoot(url: tmp, now: fixedNow)
        try AudiobookDAO(db: db.writer).save(AudiobookRecord(
            id: "bk", title: "T", author: nil, duration: 0, fileCount: nil,
            addedAt: fixedNow(), isAvailable: true, sourceRootID: root.id))

        try service.removeRoot(rootID: root.id, forgetBooks: false)
        #expect(try AudiobookDAO(db: db.writer).get("bk")?.sourceRootID == nil)
        #expect(try LibraryRootDAO(db: db.writer).get(root.id) == nil)
    }
}
```

- [ ] **Step 2: Run, verify it fails** → `make test-only FILTER=EchoTests/LibraryAvailabilityTests` FAIL (`no member 'removeRoot'`).

- [ ] **Step 3: Implement** the three methods on `LibraryService`:
```swift
func relocateRoot(rootID: String, to newURL: URL) throws {
    guard var root = try LibraryRootDAO(db: db.writer).get(rootID) else {
        throw LibraryError.unresolvableBook(rootID)
    }
    root.bookmark = LibraryAccess.makeBookmark(for: newURL) ?? Data()
    try LibraryRootDAO(db: db.writer).save(root)
}

func removeRoot(rootID: String, forgetBooks: Bool) throws {
    try db.writer.write { db in
        if forgetBooks {
            try db.execute(sql: "DELETE FROM audiobook WHERE source_root_id = ?", arguments: [rootID])
        } else {
            try db.execute(sql:
                "UPDATE audiobook SET source_root_id = NULL, is_available = 0 WHERE source_root_id = ?",
                arguments: [rootID])
        }
        try db.execute(sql: "DELETE FROM library_root WHERE id = ?", arguments: [rootID])
    }
}

func markUnavailableUnderMissingRoot(rootID: String) throws {
    _ = try db.writer.write { db in
        try db.execute(sql: "UPDATE audiobook SET is_available = 0 WHERE source_root_id = ?",
            arguments: [rootID])
    }
}
```
> Note: `removeRoot(forgetBooks: false)` also marks the kept books unavailable (their root is gone, so they can't be opened until relocated). The keep-and-mint-per-book-bookmarks variant from the spec is deferred — flag it as a follow-up; the simple version is correct and safe.

- [ ] **Step 4: Run, verify it passes** → PASS (2 tests).

- [ ] **Step 5: Commit**
```bash
git add EchoCore/Services/Library/LibraryService.swift EchoTests/LibraryAvailabilityTests.swift
git commit -m "feat(library): relocate/remove root + mark-unavailable on LibraryService"
```

---

## Task 5: `LibraryRootsViewModel` + `ManageRootsView` + "Show unavailable"

**Files:**
- Create: `EchoCore/ViewModels/LibraryRootsViewModel.swift`, `EchoCore/Views/Library/ManageRootsView.swift`
- Test: `EchoTests/LibraryRootsViewModelTests.swift`
- Modify: `EchoCore/Views/Library/LibraryView.swift` (entry point + Show-unavailable toggle wired to `vm.showUnavailable` → `reload()`)

**Interfaces:**
- Produces: `@MainActor @Observable final class LibraryRootsViewModel` — `var roots: [LibraryRootRecord]`, `func reload()`, `func rescanAll() async`, `func remove(rootID:forgetBooks:) async`, `func relocate(rootID:to:) async`; `ManageRootsView` lists roots (display name + `last_scanned_at`) with per-root Rescan + Remove (confirmation: forget-books vs keep) and a Relocate (folder picker); the Library toolbar adds a "Manage" entry + a "Show unavailable" toggle.

- [ ] **Step 1: Write the failing test** (roots VM: reload lists roots newest-first; remove drops one)
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct LibraryRootsViewModelTests {
    @Test func reloadListsRootsAndRemoveDropsOne() async throws {
        let db = try DatabaseService(inMemory: ())
        let dao = LibraryRootDAO(db: db.writer)
        try dao.save(LibraryRootRecord(id: "r1", displayName: "A", bookmark: Data(),
            addedAt: "2026-06-01T00:00:00Z", lastScannedAt: nil))
        try dao.save(LibraryRootRecord(id: "r2", displayName: "B", bookmark: Data(),
            addedAt: "2026-06-27T00:00:00Z", lastScannedAt: nil))
        let vm = LibraryRootsViewModel(db: db)
        vm.reload()
        #expect(vm.roots.map(\.id) == ["r2", "r1"])
        await vm.remove(rootID: "r1", forgetBooks: true)
        #expect(vm.roots.map(\.id) == ["r2"])
    }
}
```

- [ ] **Step 2: Run, verify it fails** → FAIL (`no 'LibraryRootsViewModel'`).

- [ ] **Step 3: Create `LibraryRootsViewModel`** (concrete, `@Observable`, mirrors `LibraryViewModel` style; `rescanAll`/`remove`/`relocate` call `LibraryService` off-main via `Task.detached` like M3 Task 7; `reload()` reads `LibraryRootDAO.all()`).

- [ ] **Step 4: Create `ManageRootsView`** — a `List` of roots (name, last-scanned, book count), per-row swipe/menu for Rescan / Relocate / Remove (with a forget-vs-keep confirmation dialog). Reuse `FolderPicker` for Relocate. Build + sim-verify.

- [ ] **Step 5: Wire into `LibraryView`** — a "Manage" toolbar item presenting `ManageRootsView` in a sheet; a "Show unavailable" toggle binding to `vm.showUnavailable` (which `reload()` already honors via `includeUnavailable:`).

- [ ] **Step 6: Run + build + sim-verify** → roots VM test PASS; Manage Roots lists/rescans/removes; Show-unavailable reveals greyed books.

- [ ] **Step 7: Commit**
```bash
git add EchoCore/ViewModels/LibraryRootsViewModel.swift EchoCore/Views/Library/ManageRootsView.swift EchoTests/LibraryRootsViewModelTests.swift EchoCore/Views/Library/LibraryView.swift
git commit -m "feat(library): Manage Roots (rescan/remove/relocate) + Show-unavailable"
```

---

## Task 6: Missing-file presentation (hide by default, badge, recovery)

**Files:**
- Modify: `EchoCore/Views/Library/LibraryCoverCell.swift` (unavailable styling), `EchoCore/ViewModels/LibraryViewModel.swift` (open-unavailable → relocate prompt)

**Interfaces:**
- Produces: unavailable books (only visible under "Show unavailable") render greyed with a "Missing" badge; tapping one offers **Relocate** (folder picker → `LibraryService.relocateRoot`) or **Remove**, rather than attempting a failing open. Default shelf (`showUnavailable == false`) excludes them — already handled by `books(includeUnavailable:)`.

- [ ] **Step 1:** Add an `isAvailable`-driven greyed style + "Missing" badge to `LibraryCoverCell` (a `book.isAvailable == false` branch).
- [ ] **Step 2:** In `LibraryViewModel`, route a tap on an unavailable book to a `relocateOrRemove(book:)` path (sets a `@Published`/observable `pendingRelocate: AudiobookRecord?` the view presents as a dialog) instead of `open(_:)`.
- [ ] **Step 3:** Build + sim-verify: with a relocated/removed folder, the book shows Missing under the toggle and offers recovery; the default shelf hides it.
- [ ] **Step 4: Commit**
```bash
git add EchoCore/Views/Library/LibraryCoverCell.swift EchoCore/ViewModels/LibraryViewModel.swift
git commit -m "feat(library): missing-file presentation + relocate/remove recovery"
```

---

## Task 7: Restore-on-relaunch for library books

**Files:**
- Modify: `EchoCore/Services/Persistence.swift`, `EchoCore/ViewModels/PlayerModel.swift`
- Test: `EchoTests/LibraryLastBookRestoreTests.swift`

**Interfaces:**
- Consumes: M3 `openLibraryBook`, `LibraryService.urlForOpening`.
- Produces: `Persistence.saveLastLibraryBook(id:)` / `lastLibraryBookID() -> String?` (a lightweight UserDefaults pointer — the book row + its root bookmark already persist in SQLite). `PlayerModel.openLibraryBook` records the id; `restoreLastSelectionIfPossible()` consults it: when `restoreBookmarkResult()` is `.none` (no picker bookmark) but a last-library-book id exists and its `audiobook` row resolves via `LibraryService.urlForOpening`, reopen it (so smart-landing's "current book if in progress" works for library books, not just picker-bookmarked ones).

- [ ] **Step 1: Write the failing test** — saving a last-library-book id and resolving it round-trips:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct LibraryLastBookRestoreTests {
    @Test func lastLibraryBookPointerRoundTrips() {
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let p = Persistence(defaults: defaults)   // confirm Persistence has a defaults-injecting init
        #expect(p.lastLibraryBookID() == nil)
        p.saveLastLibraryBook(id: "file:///Lib/Dune/")
        #expect(p.lastLibraryBookID() == "file:///Lib/Dune/")
    }
}
```
> **Confirm at implementation:** whether `Persistence` already exposes a `defaults`-injecting init (the M1/M2 grounding showed it uses `defaults` internally); if not, add one for testability, or test the pointer via a small extracted helper.

- [ ] **Step 2: Run, verify it fails** → FAIL (`no member 'lastLibraryBookID'`).

- [ ] **Step 3: Implement** the UserDefaults pointer in `Persistence`, record it in `PlayerModel.openLibraryBook`, and consult it in `restoreLastSelectionIfPossible()`'s `.none` branch:
```swift
// in restoreLastSelectionIfPossible(), the .none case:
case .none:
    if let lastID = persistence.lastLibraryBookID(),
       let db = databaseService,
       let book = try? AudiobookDAO(db: db.writer).get(lastID),
       let target = try? LibraryService(db: db).urlForOpening(book) {
        openLibraryBook(target)
    } else {
        #if DEBUG && targetEnvironment(simulator)
            if let sampleURL = MockMediaProvider.sampleAudiobookURL() {
                loadFolder(sampleURL, autoplay: false)
            }
        #endif
    }
```

- [ ] **Step 4: Run + build** → pointer test PASS; build green. Sim-verify: open a library book, relaunch → smart-landing reopens it (lands on Now Playing).

- [ ] **Step 5: Commit**
```bash
git add EchoCore/Services/Persistence.swift EchoCore/ViewModels/PlayerModel.swift EchoTests/LibraryLastBookRestoreTests.swift
git commit -m "feat(library): restore last-opened library book on relaunch"
```

---

## Task 8: Retire `FirstRunLandingView` + macOS parity

**Files:**
- Delete: `EchoCore/Views/FirstRunLandingView.swift` (now unreferenced after M3)
- Modify: macOS Library wiring (`Echo macOS/` — `MacPlayerModel` / the Mac shelf surface)

**Interfaces:**
- Produces: `FirstRunLandingView` removed; the Library brought to the macOS target (the M1/M2 core is shared-ready; `MacPlayerModel` needs an `openLibraryBook` equivalent + a Mac `LibraryView` host).

- [ ] **Step 1:** Confirm `FirstRunLandingView` has zero references (`git grep FirstRunLandingView`), delete it, build iOS — green.
- [ ] **Step 2:** Add the Library surface to macOS: a `MacPlayerModel.openLibraryBook` (mirroring iOS Task 3, using the macOS scope handling) and a Mac `LibraryView` host (reuse `LibraryViewModel`/`LibraryShelfGrid` — they're UIKit-free where possible; gate any `UIImage`-only pieces with `#if canImport(UIKit)` or provide an `NSImage` path). Build the macOS target.
- [ ] **Step 3: Run `cross-platform-parity-reviewer`** on the shared changes.
- [ ] **Step 4: Build both targets + sim-verify iOS unaffected.**
- [ ] **Step 5: Commit**
```bash
git add -A
git commit -m "chore(library): retire FirstRunLandingView; bring Library to macOS"
```

---

## Task 9: Docs

**Files:** `ARCHITECTURE.md`, `README.md`, `CHANGELOG.md`, `ROADMAP.md`

- [ ] Run the **doc-sync** skill. The Library is now a **user-facing feature** (M3+M4 shipped UI), so unlike M1/M2 it DOES belong in `README.md`'s feature list. Update the ARCHITECTURE Library section (the UI layer + the off-main rescan + the single-pass status query), flip the ROADMAP item from `[~]` to shipped, and add a CHANGELOG entry. Commit.

---

## Self-Review

- **Roadmap coverage:** facet browsing → T2/T3; single-pass status (M1/M2 FIXME #2) → T1; manage roots → T4/T5; missing-file UX → T4/T6; library-book restore → T7; drop FirstRunLandingView + macOS → T8; docs → T9. ✅
- **Placeholder scan:** the "confirm at implementation" notes (the `Persistence` defaults-init in T7; the `removeRoot(keep)` mint-bookmarks variant deferred in T4; macOS NSImage path in T8) are concrete, named, and scoped — not vague TODOs.
- **Type consistency:** `LibraryBookStatus`/`statusMap`, `LibraryRootsViewModel`, `relocateRoot`/`removeRoot`, `lastLibraryBookID`/`saveLastLibraryBook`, and the M3-defined `LibraryViewModel`/`openLibraryBook`/`libraryRoot` slot are referenced consistently.
- **Dependency note:** every task that touches `LibraryView`/`LibraryViewModel`/`openLibraryBook` is gated on M3 having landed (stated at the top). Execute M3 first.
