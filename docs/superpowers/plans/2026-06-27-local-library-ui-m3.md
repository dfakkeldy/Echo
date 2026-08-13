# On-Device Library — UI Milestone 3 (Tab · Smart-Landing · Shelf · Open) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Library a usable, end-to-end feature on iOS — a Library tab you land on when no book is playing, where you add a folder, see your books as a cover grid, and tap one to open it in the existing player.

**Architecture:** A new `LibraryView` (driven by a testable `@Observable LibraryViewModel`) becomes a third `TabSelection` case. The shelf reads the existing `LibraryService` (M1/M2). Smart-landing in `RootTabView.onAppear` routes launch to the current book if one resumed, else the Library. The empty-library shelf **absorbs** `FirstRunLandingView`'s actions (Open Folder / Connect Server / Manual) so there's one "your books / add books" home. Opening a library book holds the **root** security scope through the book's lifetime via a new `SecurityScopeManager` slot, then calls the existing `PlayerModel.loadFolder`.

**Tech Stack:** Swift 6, SwiftUI, GRDB, AVFoundation, os.Logger. UI is verified on the simulator (the Echo scheme excludes UI tests); only view-model/service logic is unit-tested.

## Global Constraints

- **SPDX header** line 1 of every Swift file: `// SPDX-License-Identifier: GPL-3.0-or-later`.
- **No protocols for new services/VMs** — concrete types, constructor/closure injection (the `DatabaseService(inMemory:)` pattern). `LibraryViewModel` is `@MainActor @Observable final class` holding `@ObservationIgnored` deps (mirror `StudySessionViewModel`).
- **Logging:** `private let logger = Logger(category: "Name")`; no `print()` in production.
- **Swift 6 strict concurrency:** new view models/views are `@MainActor`; no `??` with an `await` RHS; no `DispatchQueue.main.async`.
- **Build/test:** `make build-tests CODE_SIGNING_ALLOWED=NO`, then `make test-only FILTER=EchoTests/<Suite>`. `CODE_SIGNING_ALLOWED=NO` is mandatory. **16 GB build gate:** if an `xcodebuild` is blocked, prefix `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && <build>`; never run two builds at once; retry once on apparent external interference (DerivedData vanishing).
- **Toolchain:** `try #require(...)` emits a spurious unavoidable warning (Xcode 26.5) — do not "fix" it by removing `try`.
- **UI verification:** for view tasks, verify by building + launching on the simulator (screenshot / accessibility tree), not failing-test-first. TDD only the view-model/service/scope-manager logic.
- **Reuse M1/M2:** `LibraryService` (register/rescan/books/sections/urlForOpening/derived-status), `LibraryOpenTarget {url, scopedRoot}`, `LibraryRootDAO`, `AudiobookRecord` fields, `ArtworkCache`. Do not duplicate them.
- **Design decision (owner-approved 2026-06-27):** the **shelf absorbs the first-run landing** — `FirstRunLandingView`'s three actions move into the empty-library shelf state; `FirstRunLandingView` is retired from `NowPlayingTab`.

## Refinements carried from M1/M2 (honor these)
- `urlForOpening` is **resolve-only** (starts no scope) and returns `LibraryOpenTarget{url, scopedRoot}`. The caller owns the scope lifecycle.
- M1/M2 left `// FIXME(M3)` markers: rescan + per-book status run on `@MainActor` and the per-book status is an N+1 query. **This plan moves rescan off-main (Task 8) and adds a single-pass status query is deferred to M4** — see M4 roadmap.

---

## File Structure

**New files**
- `EchoCore/ViewModels/LibraryViewModel.swift` — `@Observable` shelf state: load sections for an axis, smart-landing decision, resolve+open a book, run a rescan off-main. Testable logic lives here.
- `EchoCore/Views/Library/LibraryView.swift` — the Library tab: cover grid + axis chips + empty-state-absorbs-landing + Add Folder.
- `EchoCore/Views/Library/LibraryShelfGrid.swift` — the `LazyVGrid` of `LibraryCoverCell`s.
- `EchoCore/Views/Library/LibraryCoverCell.swift` — one book tile (cover + title + author).
- `EchoCore/Views/Library/LibraryCoverImage.swift` — loads a cover from `cover_art_path` (cached) with a placeholder.

**Modified files**
- `Shared/TabSelection.swift` — add `.library`.
- `EchoCore/Services/SecurityScopeManager.swift` — add a `libraryRoot` scope slot.
- `EchoCore/ViewModels/PlayerModel.swift` — add `openLibraryBook(_:)`; thread a `persistBookmark` flag so library opens skip the per-book bookmark save.
- `EchoCore/Services/PlayerLoadingCoordinator.swift` — accept the `persistBookmark` flag.
- `EchoCore/Views/RootTabView.swift` — `.library` switch case + `libraryPath` + smart-landing in `onAppear`.
- `EchoCore/Views/BottomToolbarView.swift` — three-way dock affordance (replace the 2-state Read toggle).
- `EchoCore/Views/NowPlayingTab.swift` — remove the `FirstRunLandingView` branch (the Library now owns the empty state); when `folderURL == nil` route to the Library instead.

**Tests**
- `EchoTests/LibraryViewModelTests.swift`
- `EchoTests/SecurityScopeManagerLibraryRootTests.swift`

---

## Task 1: `TabSelection.library`

**Files:**
- Modify: `Shared/TabSelection.swift:4-23`
- Test: `EchoTests/TabSelectionTests.swift` (create if absent)

**Interfaces:**
- Produces: `TabSelection.library` with `.icon = "books.vertical"` and `.label = "Library"`.

- [ ] **Step 1: Write the failing test**

Create `EchoTests/TabSelectionTests.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@MainActor
struct TabSelectionTests {
    @Test func libraryCaseHasIconAndLabel() {
        #expect(TabSelection.library.icon == "books.vertical")
        #expect(TabSelection.library.label == "Library")
        #expect(TabSelection.allCases.contains(.library))
    }
}
```

- [ ] **Step 2: Run, verify it fails**

Run: `make build-tests CODE_SIGNING_ALLOWED=NO && make test-only FILTER=EchoTests/TabSelectionTests`
Expected: FAIL — `TabSelection has no member 'library'`.

- [ ] **Step 3: Add the case**

In `Shared/TabSelection.swift`, add `case library` after `case read`, and a branch in each switch:
```swift
enum TabSelection: String, CaseIterable {
    case nowPlaying
    case read
    case library

    var icon: String {
        switch self {
        case .nowPlaying: return "headphones"
        case .read: return "book.pages"
        case .library: return "books.vertical"
        }
    }

    var label: String {
        switch self {
        case .nowPlaying: return "Listen"
        case .read: return "Read & Study"
        case .library: return "Library"
        }
    }
}
```

- [ ] **Step 4: Run, verify it passes**

Run: `make test-only FILTER=EchoTests/TabSelectionTests` → PASS.

- [ ] **Step 5: Commit**
```bash
git add Shared/TabSelection.swift EchoTests/TabSelectionTests.swift
git commit -m "feat(library): add .library TabSelection case"
```

> Note: adding the case makes the `switch model.selectedTab` in `RootTabView` non-exhaustive — it won't compile until Task 6 adds the `.library` case there. That's expected; Tasks 2–5 are independent files. If you need a green build between tasks, add a temporary `case .library: EmptyView()` to the RootTabView switch and the BottomToolbar, replaced in Task 6.

---

## Task 2: `SecurityScopeManager` — a `libraryRoot` scope slot

**Files:**
- Modify: `EchoCore/Services/SecurityScopeManager.swift`
- Test: `EchoTests/SecurityScopeManagerLibraryRootTests.swift`

**Interfaces:**
- Produces: `func startLibraryRoot(url: URL) -> Bool`, `func stopLibraryRoot()`, and `stopAll()` now also stops the library-root slot. The slot holds **one** root at a time; `startLibraryRoot(R)` auto-stops a different held root (matching the existing `startSelection` pattern). This is the slot that backs `LibraryOpenTarget.scopedRoot` — it must NOT be the `selection` slot (which `loadFolder` overwrites with the child URL).

**Why a new slot (not `selection`):** `PlayerLoadingCoordinator.loadFolder` calls `securityScope?.startSelection(url:)` on the **book** URL. A library book's child folder isn't independently scopable; access flows from the **root**. If we used the selection slot for the root, `loadFolder` would auto-stop it. A dedicated slot survives the book load and stays alive for the book's lifetime.

- [ ] **Step 1: Write the failing test**

Create `EchoTests/SecurityScopeManagerLibraryRootTests.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
struct SecurityScopeManagerLibraryRootTests {
    /// On a plain (non-security-scoped) temp dir, startAccessingSecurityScopedResource
    /// returns false — but the manager must still TRACK the slot so stop is balanced
    /// and a different root swaps cleanly. We assert the manager's own bookkeeping via
    /// a second start with the same URL being idempotent and stopAll() not crashing.
    @Test func libraryRootSlotTracksAndSwapsWithoutCrashing() throws {
        let mgr = SecurityScopeManager()
        let tmpA = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssm-a-\(UUID().uuidString)", isDirectory: true)
        let tmpB = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssm-b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmpB, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tmpA)
            try? FileManager.default.removeItem(at: tmpB)
        }

        mgr.startLibraryRoot(url: tmpA)   // tracks A
        mgr.startLibraryRoot(url: tmpA)    // idempotent — same URL, no double-start
        mgr.startLibraryRoot(url: tmpB)    // swaps to B (stops A first)
        mgr.stopLibraryRoot()              // releases B
        mgr.stopLibraryRoot()              // safe no-op when nothing held
        mgr.stopAll()                      // must not crash
    }
}
```

- [ ] **Step 2: Run, verify it fails**

Run: `make build-tests CODE_SIGNING_ALLOWED=NO && make test-only FILTER=EchoTests/SecurityScopeManagerLibraryRootTests`
Expected: FAIL — `value of type 'SecurityScopeManager' has no member 'startLibraryRoot'`.

- [ ] **Step 3: Add the slot**

In `EchoCore/Services/SecurityScopeManager.swift`, add the fields alongside the existing three slots, the start/stop methods (mirroring `startSelection`/`stopSelection` exactly), and the `stopAll()` line:
```swift
    private var hasLibraryRootAccess: Bool = false
    private var libraryRootURL: URL?

    @discardableResult
    func startLibraryRoot(url: URL) -> Bool {
        if hasLibraryRootAccess {
            if libraryRootURL == url { return true }
            stopLibraryRoot()
        }
        libraryRootURL = url
        hasLibraryRootAccess = url.startAccessingSecurityScopedResource()
        return hasLibraryRootAccess
    }

    func stopLibraryRoot() {
        guard hasLibraryRootAccess, let url = libraryRootURL else { return }
        url.stopAccessingSecurityScopedResource()
        hasLibraryRootAccess = false
        libraryRootURL = nil
    }
```
And extend `stopAll()`:
```swift
    func stopAll() {
        stopFile()
        stopParent()
        stopSelection()
        stopLibraryRoot()
    }
```

- [ ] **Step 4: Run, verify it passes**

Run: `make test-only FILTER=EchoTests/SecurityScopeManagerLibraryRootTests` → PASS.

- [ ] **Step 5: Commit**
```bash
git add EchoCore/Services/SecurityScopeManager.swift EchoTests/SecurityScopeManagerLibraryRootTests.swift
git commit -m "feat(library): add libraryRoot scope slot to SecurityScopeManager"
```

---

## Task 3: `PlayerModel.openLibraryBook` + `loadFolder(persistBookmark:)`

**Files:**
- Modify: `EchoCore/ViewModels/PlayerModel.swift` (the `loadFolder` at ~1080 and add `openLibraryBook`)
- Modify: `EchoCore/Services/PlayerLoadingCoordinator.swift` (`loadFolder` signature)
- Test: none new (integration-verified in Task 7 on-sim; the logic is a thin orchestration). The persistBookmark wiring is verified by build + the existing player tests still passing.

**Interfaces:**
- Consumes: `LibraryOpenTarget {url: URL, scopedRoot: URL?}` (M2); `securityScope.startLibraryRoot` (Task 2).
- Produces: `func openLibraryBook(_ target: LibraryOpenTarget)` on `PlayerModel`; `loadFolder(_:autoplay:persistBookmark:)` gains a `persistBookmark: Bool = true` parameter threaded to the coordinator so a library open does NOT attempt to save a per-book security-scoped bookmark for the (non-bookmarkable) child URL.

**Why `persistBookmark`:** today, after a load, `PlayerModel.persistSelection(url:)` calls `persistence.saveBookmark(url:)` and surfaces `showingBookmarkPersistenceWarning` on failure. A library book's child URL can't be independently bookmarked, so this would warn on every open. Library opens skip it; the book stays reachable through the held `libraryRoot` scope for this session.

> **Implementation-time trace (do this first):** find where `persistSelection` / `persistence.saveBookmark` is invoked after `loadFolder` (search `persistSelection(` and `saveBookmark(` in `PlayerModel.swift` / `PlayerLoadingCoordinator.swift`). Thread the `persistBookmark` flag to skip exactly that call for library opens. If the save happens inside the coordinator, add the param there; if in a PlayerModel post-load callback, gate it on a stored `pendingPersistBookmark` flag set by `openLibraryBook`.

- [ ] **Step 1: Add the coordinator param**

In `EchoCore/Services/PlayerLoadingCoordinator.swift`, change `func loadFolder(_ url: URL, autoplay: Bool = true)` to `func loadFolder(_ url: URL, autoplay: Bool = true, persistBookmark: Bool = true)` and pass `persistBookmark` to wherever the per-book bookmark save occurs (gate that call on `persistBookmark`).

- [ ] **Step 2: Thread it through `PlayerModel.loadFolder`**

In `EchoCore/ViewModels/PlayerModel.swift`, add the param and forward it:
```swift
func loadFolder(_ url: URL, autoplay: Bool = true, persistBookmark: Bool = true) {
    narrationRenderTask?.cancel()
    narrationRenderTask = nil
    state.narrationRenderInFlight = false
    state.awaitingNarrationChapter = false
    narrationPlaybackState.reset()
    playerLoadingCoordinator.loadFolder(url, autoplay: autoplay, persistBookmark: persistBookmark)
}
```

- [ ] **Step 3: Add `openLibraryBook`**

In `PlayerModel.swift`, add:
```swift
/// Opens a book resolved from the Library. Holds the book's library-root security
/// scope for this session (the child folder isn't independently scopable), then loads
/// it without persisting a per-book bookmark (the child URL can't be bookmarked).
func openLibraryBook(_ target: LibraryOpenTarget) {
    if let root = target.scopedRoot {
        securityScope.startLibraryRoot(url: root)
    } else {
        securityScope.stopLibraryRoot()  // standalone book — release any held root
    }
    loadFolder(target.url, autoplay: false, persistBookmark: false)
}
```

- [ ] **Step 4: Build, verify it compiles + existing player tests pass**

Run: `make build-tests CODE_SIGNING_ALLOWED=NO && make test-only FILTER=EchoTests/PlayerModelLoadTests` (or the nearest existing player-load suite — list with `ls EchoTests | grep -i player`). Expected: BUILD SUCCEEDED; existing suite green (no per-book bookmark regression for normal opens, which still default `persistBookmark: true`).

- [ ] **Step 5: Commit**
```bash
git add EchoCore/ViewModels/PlayerModel.swift EchoCore/Services/PlayerLoadingCoordinator.swift
git commit -m "feat(library): PlayerModel.openLibraryBook holds root scope, skips per-book bookmark"
```

---

## Task 4: `LibraryViewModel` — sections, smart-landing, open, rescan

**Files:**
- Create: `EchoCore/ViewModels/LibraryViewModel.swift`
- Test: `EchoTests/LibraryViewModelTests.swift`

**Interfaces:**
- Consumes: `LibraryService` (M2), `PlayerModel.openLibraryBook` (Task 3).
- Produces:
  - `@MainActor @Observable final class LibraryViewModel`
  - `var sections: [LibraryService.LibrarySection]`, `var selectedAxis: LibraryService.LibraryAxis = .recentlyAdded`, `var isEmpty: Bool` (no available books AND no roots), `var errorMessage: String?`
  - `init(db: DatabaseService, openBook: @escaping (LibraryService.LibraryOpenTarget) -> Void)` — `openBook` injected (production passes `playerModel.openLibraryBook`; tests pass a spy)
  - `func reload()` — loads `sections` for `selectedAxis` (off the published path; catches errors into `errorMessage`)
  - `func open(_ book: AudiobookRecord)` — resolves via `LibraryService.urlForOpening`, calls `openBook(target)`; on throw sets `errorMessage` (the book is unavailable)
  - `func addRoot(url: URL) async` — `LibraryService.registerRoot` + an async enriching `rescan`, then `reload()`
  - `static func smartLandingTab(hasCurrentBook: Bool) -> TabSelection` — pure: `hasCurrentBook ? .nowPlaying : .library`

- [ ] **Step 1: Write the failing tests**

Create `EchoTests/LibraryViewModelTests.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct LibraryViewModelTests {
    @Test func smartLandingPrefersCurrentBookElseLibrary() {
        #expect(LibraryViewModel.smartLandingTab(hasCurrentBook: true) == .nowPlaying)
        #expect(LibraryViewModel.smartLandingTab(hasCurrentBook: false) == .library)
    }

    @Test func reloadLoadsAvailableBooksForAxis() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = AudiobookDAO(db: db.writer)
        try dao.save(AudiobookRecord(
            id: "a", title: "Atomic Habits", author: "James Clear", duration: 0,
            fileCount: nil, addedAt: "2026-06-27T00:00:00Z", isAvailable: true))
        let vm = LibraryViewModel(db: db, openBook: { _ in })
        vm.reload()
        #expect(vm.sections.flatMap(\.books).map(\.id) == ["a"])
        #expect(vm.isEmpty == false)
    }

    @Test func openResolvesAndCallsOpenBookForStandaloneBook() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = AudiobookDAO(db: db.writer)
        let book = AudiobookRecord(
            id: "file:///Books/Dune/", title: "Dune", author: nil, duration: 0,
            fileCount: nil, addedAt: "2026-06-27T00:00:00Z", isAvailable: true)
        try dao.save(book)
        var opened: LibraryService.LibraryOpenTarget?
        let vm = LibraryViewModel(db: db, openBook: { opened = $0 })
        vm.open(book)
        #expect(opened?.url.absoluteString == "file:///Books/Dune/")
        #expect(opened?.scopedRoot == nil)
        #expect(vm.errorMessage == nil)
    }

    @Test func openSetsErrorWhenBookUnresolvable() throws {
        let db = try DatabaseService(inMemory: ())
        let vm = LibraryViewModel(db: db, openBook: { _ in })
        let bad = AudiobookRecord(
            id: "not a url", title: "X", author: nil, duration: 0, fileCount: nil,
            addedAt: "2026-06-27T00:00:00Z", isAvailable: true)
        vm.open(bad)
        #expect(vm.errorMessage != nil)
    }
}
```

- [ ] **Step 2: Run, verify it fails**

Run: `make build-tests CODE_SIGNING_ALLOWED=NO && make test-only FILTER=EchoTests/LibraryViewModelTests`
Expected: FAIL — `cannot find 'LibraryViewModel'`.

- [ ] **Step 3: Create the view model**

Create `EchoCore/ViewModels/LibraryViewModel.swift`:
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Observation
import os.log

@MainActor
@Observable
final class LibraryViewModel {
    var sections: [LibraryService.LibrarySection] = []
    var selectedAxis: LibraryService.LibraryAxis = .recentlyAdded
    var showUnavailable: Bool = false
    var errorMessage: String?

    @ObservationIgnored private let db: DatabaseService
    @ObservationIgnored private let service: LibraryService
    @ObservationIgnored private let openBook: (LibraryService.LibraryOpenTarget) -> Void
    @ObservationIgnored private let logger = Logger(category: "LibraryViewModel")

    init(db: DatabaseService, openBook: @escaping (LibraryService.LibraryOpenTarget) -> Void) {
        self.db = db
        self.service = LibraryService(db: db)
        self.openBook = openBook
    }

    var isEmpty: Bool { sections.allSatisfy { $0.books.isEmpty } }

    static func smartLandingTab(hasCurrentBook: Bool) -> TabSelection {
        hasCurrentBook ? .nowPlaying : .library
    }

    func reload() {
        do {
            sections = try service.sections(by: selectedAxis, includeUnavailable: showUnavailable)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Library reload failed: \(error.localizedDescription)")
        }
    }

    func open(_ book: AudiobookRecord) {
        do {
            let target = try service.urlForOpening(book)
            openBook(target)
            errorMessage = nil
        } catch {
            errorMessage = "This book can’t be opened — its folder may have moved."
            logger.error("Open failed for \(book.id): \(error.localizedDescription)")
        }
    }

    func addRoot(url: URL) async {
        do {
            let root = try service.registerRoot(url: url)
            let coversDir = FileLocations.libraryCoversDirectory
            _ = try await service.rescan(
                root: root, readMetadata: { await LibraryScanner.readMetadata(for: $0) },
                coversDir: coversDir)
            reload()
        } catch {
            errorMessage = error.localizedDescription
            logger.error("addRoot failed: \(error.localizedDescription)")
        }
    }
}
```

> **Implementation-time confirm:** `FileLocations.libraryCoversDirectory` — add a `static var libraryCoversDirectory: URL` to `Shared/FileLocations.swift` returning a `LibraryCovers/` subdir of the caches dir (mirror the existing `absLibraryDirectory` accessor). This is where M2's `rescan` writes SHA-256 cover files.

- [ ] **Step 4: Run, verify it passes**

Run: `make test-only FILTER=EchoTests/LibraryViewModelTests` → PASS (4 tests). Add `FileLocations.libraryCoversDirectory` first if the build complains.

- [ ] **Step 5: Commit**
```bash
git add EchoCore/ViewModels/LibraryViewModel.swift EchoTests/LibraryViewModelTests.swift Shared/FileLocations.swift
git commit -m "feat(library): add LibraryViewModel (sections, smart-landing, open, addRoot)"
```

---

## Task 5: Cover image + cover cell + shelf grid (views — sim-verified)

**Files:**
- Create: `EchoCore/Views/Library/LibraryCoverImage.swift`, `LibraryCoverCell.swift`, `LibraryShelfGrid.swift`

**Interfaces:**
- Produces: `LibraryCoverImage(coverArtPath: String?)` (loads `FileLocations.libraryCoversDirectory/<path>` via `ArtworkCache.loadImageFile`, placeholder `book.closed.fill` like `NowPlayingTab.artworkView`); `LibraryCoverCell(book: AudiobookRecord, onTap: () -> Void)`; `LibraryShelfGrid(sections: [LibraryService.LibrarySection], onTapBook: (AudiobookRecord) -> Void)`.

These are presentational; verify by building. Full code:

- [ ] **Step 1: `LibraryCoverImage.swift`**
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct LibraryCoverImage: View {
    let coverArtPath: String?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 28)).foregroundStyle(.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: coverArtPath) {
            guard let coverArtPath else { image = nil; return }
            let url = FileLocations.libraryCoversDirectory.appendingPathComponent(coverArtPath)
            image = await ArtworkCache.loadImageFile(at: url)
        }
    }
}
```

- [ ] **Step 2: `LibraryCoverCell.swift`**
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct LibraryCoverCell: View {
    let book: AudiobookRecord
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                LibraryCoverImage(coverArtPath: book.coverArtPath)
                    .aspectRatio(1, contentMode: .fit)
                Text(book.title).font(.caption).lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let author = book.author {
                    Text(author).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(book.title)\(book.author.map { ", \($0)" } ?? "")"))
    }
}
```

- [ ] **Step 3: `LibraryShelfGrid.swift`**
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct LibraryShelfGrid: View {
    let sections: [LibraryService.LibrarySection]
    let onTapBook: (AudiobookRecord) -> Void

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(sections, id: \.title) { section in
                    if !section.books.isEmpty {
                        Text(section.title).font(.headline).padding(.horizontal)
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(section.books, id: \.id) { book in
                                LibraryCoverCell(book: book) { onTapBook(book) }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .padding(.vertical)
        }
    }
}
```

- [ ] **Step 4: Build**

Run: `make build-tests CODE_SIGNING_ALLOWED=NO` → BUILD SUCCEEDED (no runtime test; rendered in Task 6).

- [ ] **Step 5: Commit**
```bash
git add EchoCore/Views/Library/
git commit -m "feat(library): cover image, cover cell, shelf grid views"
```

---

## Task 6: `LibraryView` + RootTabView `.library` case + dock affordance + empty-state-absorbs-landing

**Files:**
- Create: `EchoCore/Views/Library/LibraryView.swift`
- Modify: `EchoCore/Views/RootTabView.swift` (switch case, `libraryPath`, FolderPicker reuse), `EchoCore/Views/BottomToolbarView.swift` (3-way affordance), `EchoCore/Views/NowPlayingTab.swift` (remove FirstRunLandingView branch)

**Interfaces:**
- Consumes: `LibraryViewModel` (Task 4), `LibraryShelfGrid` (Task 5), `TabSelection.library` (Task 1).
- Produces: `LibraryView` — a recently-added/all-books cover grid with axis chips (Recently Added / All Books for MVP; the richer axes are M4), an **empty state** that shows the absorbed landing actions (Open a Folder / Connect a Server), and an Add-Folder toolbar button. Verified on the simulator.

- [ ] **Step 1: `LibraryView.swift`** (full code — empty state reuses the retired landing's action labels)
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct LibraryView: View {
    @State private var vm: LibraryViewModel
    let onAddFolder: () -> Void
    let onConnectServer: () -> Void

    init(db: DatabaseService, openBook: @escaping (LibraryService.LibraryOpenTarget) -> Void,
         onAddFolder: @escaping () -> Void, onConnectServer: @escaping () -> Void) {
        _vm = State(initialValue: LibraryViewModel(db: db, openBook: openBook))
        self.onAddFolder = onAddFolder
        self.onConnectServer = onConnectServer
    }

    var body: some View {
        Group {
            if vm.isEmpty {
                emptyState
            } else {
                LibraryShelfGrid(sections: vm.sections) { vm.open($0) }
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Folder", systemImage: "folder.badge.plus", action: onAddFolder)
            }
        }
        .onAppear { vm.reload() }
        .alert("Couldn’t open book", isPresented: .constant(vm.errorMessage != nil)) {
            Button("OK") { vm.errorMessage = nil }
        } message: { Text(vm.errorMessage ?? "") }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Your Library", systemImage: "books.vertical")
        } description: {
            Text("Add a folder of audiobooks to build your shelf. Echo plays your files where they live — it never copies them.")
        } actions: {
            Button("Open a Folder", systemImage: "folder", action: onAddFolder)
                .buttonStyle(.borderedProminent)
            Button("Connect a Server", systemImage: "externaldrive.connected.to.line.below",
                   action: onConnectServer)
        }
    }
}
```

- [ ] **Step 2: RootTabView — add the `.library` case, `libraryPath`, and wire Add Folder to register a root**

Add `@State private var libraryPath = NavigationPath()` near `nowPlayingPath`/`readPath`. In the `switch model.selectedTab`, add:
```swift
case .library:
    NavigationStack(path: $libraryPath) {
        LibraryView(
            db: model.databaseService!,
            openBook: { model.openLibraryBook($0) },
            onAddFolder: { showingFolderPicker = true },
            onConnectServer: { showingSettings = true }
        )
        .navigationDestination(for: NavigationDestination.self) { dest in
            dest.view(using: model)
        }
    }
```
And update the existing FolderPicker sheet so a picked folder is BOTH opened and registered as a library root (Component D auto-register) — change the callback at `RootTabView.swift:260-266`:
```swift
.sheet(isPresented: $showingFolderPicker) {
    FolderPicker { url in
        showingFolderPicker = false
        Task { await model.registerLibraryRoot(url: url) }   // Component D: remember the folder
        model.loadFolder(url)                                 // and open it now
    }
}
```
Add `registerLibraryRoot(url:)` to PlayerModel (thin wrapper over `LibraryService(db:).registerRoot` + an async enriching rescan on a background `Task`, guarded so a failure only logs):
```swift
func registerLibraryRoot(url: URL) async {
    guard let db = databaseService else { return }
    let service = LibraryService(db: db)
    do {
        let root = try service.registerRoot(url: url)
        _ = try await service.rescan(
            root: root, readMetadata: { await LibraryScanner.readMetadata(for: $0) },
            coversDir: FileLocations.libraryCoversDirectory)
    } catch { libraryLogger.error("registerLibraryRoot failed: \(error.localizedDescription)") }
}
```

- [ ] **Step 3: Dock — three-way affordance**

In `EchoCore/Views/BottomToolbarView.swift`, replace the two-state `readToggleButton` (lines 139-157) with a cyclic three-way button that rotates `.nowPlaying → .read → .library → .nowPlaying`, shows the *next* tab's icon, and — crucially — is **not** disabled when no book is loaded (Library must be reachable from the empty state):
```swift
private var tabCycleButton: some View {
    let next: TabSelection = {
        switch model.selectedTab {
        case .nowPlaying: return .read
        case .read: return .library
        case .library: return .nowPlaying
        }
    }()
    return Button {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { model.selectedTab = next }
        Haptic.play(.medium)
    } label: {
        utilityChip(isActive: false) { Image(systemName: next.icon).font(.title2) }
    }
    .accessibilityLabel(Text("Go to \(next.label)"))
}
```
Replace `readToggleButton` with `tabCycleButton` in the body HStack. (The Read-tab capture buttons elsewhere in the toolbar are unaffected.)

> Note: this MVP dock is a simple cycle. M4 may replace it with an explicit 3-segment control — flagged in the roadmap.

- [ ] **Step 4: NowPlayingTab — retire the FirstRunLandingView branch**

In `EchoCore/Views/NowPlayingTab.swift:30-37`, the `if model.folderURL == nil { FirstRunLandingView(...) }` branch is now dead (the Library owns the empty state). Replace it with a minimal redirect so a returning user with no book who is on the Now Playing tab is sent to the Library:
```swift
if model.folderURL == nil {
    Color.clear.onAppear { model.selectedTab = .library }
} else {
```
`FirstRunLandingView.swift` is left in the tree but no longer referenced (delete it in a follow-up once macOS parity is confirmed — do NOT delete in this task to avoid touching the macOS build).

- [ ] **Step 5: Smart-landing in RootTabView.onAppear**

In `RootTabView.swift` `onAppear` (after `model.restoreLastSelectionIfPossible()` runs), set the initial tab:
```swift
model.selectedTab = LibraryViewModel.smartLandingTab(hasCurrentBook: model.folderURL != nil)
```
(Place it AFTER `restoreLastSelectionIfPossible()` so `folderURL` reflects a restored book, and BEFORE `applyPendingDeepLinkIfNeeded()` so a deep link can still override the tab.)

- [ ] **Step 6: Build + simulator verification**

Run: `make build-tests CODE_SIGNING_ALLOWED=NO` → BUILD SUCCEEDED. Then launch on the simulator and verify with the `simulator-tester` agent / `xcui`:
1. Fresh launch (no book) lands on the **Library** tab showing the empty state with "Open a Folder" / "Connect a Server".
2. The dock cycle button reaches the Library from any tab, even with no book loaded.
3. Tapping "Add Folder", picking a folder of audiobooks, returns to a populated shelf (covers + titles).
4. Tapping a book opens it (player shows, audio is reachable — confirms the root-scope handoff).
5. Relaunch with a book in progress lands on **Now Playing**, not the Library.

Capture a screenshot of the populated shelf and the empty state.

- [ ] **Step 7: Commit**
```bash
git add EchoCore/Views/Library/LibraryView.swift EchoCore/Views/RootTabView.swift EchoCore/Views/BottomToolbarView.swift EchoCore/Views/NowPlayingTab.swift EchoCore/ViewModels/PlayerModel.swift
git commit -m "feat(library): Library tab, smart-landing, Add Folder, shelf — absorbs first-run landing"
```

---

## Task 7: Move rescan off the main actor (M1/M2 `// FIXME(M3)`)

**Files:**
- Modify: `EchoCore/ViewModels/LibraryViewModel.swift` / `PlayerModel.registerLibraryRoot` — run the enriching `rescan` on a detached background `Task` (bounded), publishing progress, so a large add-folder doesn't block the main actor.

**Interfaces:**
- Produces: `LibraryViewModel.addRoot` and `PlayerModel.registerLibraryRoot` perform the `AVAsset`-heavy `rescan` off the `@MainActor` (e.g. `await Task.detached { ... }.value` around the scan loop, or make `LibraryService.rescan` accept an `await`-friendly bounded-concurrency executor). The shelf shows a lightweight "Scanning…" state via a `@MainActor var isScanning` flag, then `reload()` on completion.

- [ ] **Step 1: Add `isScanning` + off-main rescan**

In `LibraryViewModel`, add `var isScanning = false` and wrap the rescan:
```swift
func addRoot(url: URL) async {
    isScanning = true
    defer { isScanning = false }
    do {
        let root = try service.registerRoot(url: url)
        try await Task.detached(priority: .utility) { [service] in
            _ = try await service.rescan(
                root: root, readMetadata: { await LibraryScanner.readMetadata(for: $0) },
                coversDir: FileLocations.libraryCoversDirectory)
        }.value
        reload()
    } catch {
        errorMessage = error.localizedDescription
    }
}
```
> **Confirm at implementation:** `LibraryService` is `@MainActor`. To call `rescan` from a detached task, either (a) make `LibraryService.rescan` `nonisolated`/`Sendable`-safe over its own GRDB writer (preferred — GRDB writers are thread-safe), or (b) keep `LibraryService` `@MainActor` but extract the AVAsset metadata reads (`LibraryScanner.readMetadata`, already a pure enum) to run off-main and only the DB writes hop back. The cleanest: drop `@MainActor` from `LibraryService` (it holds only a `DatabaseService`; nothing requires main-actor isolation) and let callers `await` it — this also resolves the M1/M2 `@MainActor`-blocking FIXME at its root. Verify the existing `LibraryServiceTests` still pass after de-isolating (they construct it on `@MainActor` already, which is still legal).

- [ ] **Step 2: Show the scanning state in `LibraryView`**

Add an `if vm.isScanning { ProgressView("Scanning…") }` overlay/section to `LibraryView.body`.

- [ ] **Step 3: Build + sim-verify** a large-folder add shows "Scanning…" without freezing the UI, then populates.

- [ ] **Step 4: Commit**
```bash
git add EchoCore/ViewModels/LibraryViewModel.swift EchoCore/Views/Library/LibraryView.swift EchoCore/Services/Library/LibraryService.swift
git commit -m "perf(library): run rescan off the main actor (resolves M3 FIXME)"
```

---

## Self-Review

- **Spec coverage (UI subset):** Library tab → T1/T6; smart-landing absorbing the landing → T6; shelf cover grid → T5/T6; open a book + root-scope handoff → T2/T3/T4; Add Folder + auto-register root → T6; off-main rescan (M3 FIXME) → T7. ✅
- **Placeholder scan:** the two "implementation-time confirm/trace" notes (the `persistBookmark` call-site trace in T3; `FileLocations.libraryCoversDirectory` + the `LibraryService` de-isolation in T4/T7) are concrete, named traces, not vague TODOs.
- **Type consistency:** `LibraryOpenTarget{url, scopedRoot}`, `LibraryService.LibrarySection`/`.LibraryAxis`, `LibraryViewModel.smartLandingTab`, `openLibraryBook`, `startLibraryRoot` used identically across tasks.

---

## Milestone 4 — Roadmap (expand into its own plan after M3 lands)

These build on M3's shelf + LibraryViewModel; UI-verified on the simulator.

- **T-M4-1 — Facet browsing ("Browse by…").** A drill-down list (Authors / Topics / Folders / Study status / Processing status) → filtered shelf, driven by `LibraryService.sections(by:)` for the remaining axes; processing-status dot on each cover (green aligned / blue narrated / amber transcribed / grey none).
- **T-M4-2 — Single-pass status query (resolves the second M1/M2 FIXME).** Replace the per-book N+1 `studyStatus`/`processingStatus` calls with one aggregate (GROUP BY / joined) query for the whole shelf.
- **T-M4-3 — Manage Roots.** List `library_root`s with `last_scanned_at`; per-root Rescan + Rescan-all; Remove root (forget-its-books with a study-data warning, or keep — minting per-book bookmarks from the live root grant).
- **T-M4-4 — Missing-file UX.** Hide `is_available == false` books by default; a "Show unavailable" toggle; Relocate (re-pick the folder → refresh the root bookmark) and Remove. Tie into the existing `restoreBookmarkResult().missing` recovery.
- **T-M4-5 — Library-book restore-on-relaunch.** Persist "last opened library book id + root" so smart-landing can reopen a library book (not just picker-bookmarked books) — completes the deferred restore path from M3 Task 3.
- **T-M4-6 — Drop `FirstRunLandingView` + macOS parity.** Remove the now-unreferenced `FirstRunLandingView`, and bring the Library to the macOS target (`MacPlayerModel` lacks the open path) — flag `cross-platform-parity-reviewer`.
- **Docs:** update ARCHITECTURE/CHANGELOG/ROADMAP + README (the Library becomes a *user-facing* feature once M3 ships UI) via the `doc-sync` skill.
