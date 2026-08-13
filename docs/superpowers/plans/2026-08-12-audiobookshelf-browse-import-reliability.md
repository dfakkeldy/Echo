# Audiobookshelf Browse and Import Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Echo matching iOS and macOS Audiobookshelf sorting/filtering plus a staged, progress-reporting import flow that never silently dismisses and only reports Added after a usable local book is committed.

**Architecture:** Audiobookshelf remains a download-to-local source. A platform-neutral `ABSBrowseModel` owns complete-library query state, local provenance status, and per-item import state; native iOS and macOS views render that model. Audiobookshelf performs paging, ordinary sorts, and each individual metadata-filter query, while Echo combines complete result-ID sets for multi-select filters, performs the unsupported whole-library series sort locally, and validates import output against Echo's actual supported root-level content before publishing it.

**Tech Stack:** Swift 6, SwiftUI, Observation, Foundation `URLSession`, GRDB, ZIPFoundation, Swift Testing, OSLog, Xcode 26 toolchain.

**Approved spec:** `docs/superpowers/specs/2026-08-12-audiobookshelf-browse-import-reliability-design.md`

## Global Constraints

- Preserve deployment floors: iOS 18, macOS 15, watchOS 11.
- Preserve Swift 6 strict concurrency and default Main Actor isolation; network, archive, and filesystem-heavy work must remain off the UI actor.
- Do not add a third-party dependency.
- Use concrete constructor/closure injection; do not add an Audiobookshelf protocol.
- Keep credentials, tokens, server response bodies, private paths, book titles, and book metadata out of logs and committed fixtures.
- Preserve localization, Dynamic Type, and accessibility behavior for every new control and state.
- Keep streaming, resumable background transfers, and listening-status filters out of scope.
- Run every Apple build/test through `/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- <command>`.
- Preserve unrelated untracked files `docs/superpowers/plans/2026-08-02-macos-performance-remediation.md` and `file.txt`.
- Target the eventual PR to `nightly` and use Conventional Commits.

## File Structure

New production files:

- `EchoCore/Services/Audiobookshelf/ABSBrowseTypes.swift` — sort/filter/query values, filter set algebra, and stable ordering.
- `EchoCore/Services/Audiobookshelf/ABSImportProgress.swift` — sendable progress, stage, failure, and imported-book contracts.
- `EchoCore/ViewModels/ABSBrowseModel.swift` — shared observable browse/search/filter/paging/import state.
- `Echo macOS/Views/MacAudiobookshelfBrowseView.swift` — native macOS browser bound to the shared model.

Modified production files:

- `EchoCore/Services/Audiobookshelf/ABSModels.swift`
- `EchoCore/Services/Audiobookshelf/ABSEndpoints.swift`
- `EchoCore/Services/Audiobookshelf/AudiobookshelfService.swift`
- `EchoCore/Services/Audiobookshelf/ABSImportService.swift`
- `Shared/Database/DAOs/AudiobookDAO.swift`
- `EchoCore/ViewModels/PlayerModel+Audiobookshelf.swift`
- `EchoCore/Views/ABSConnectionsSettingsView.swift`
- `EchoCore/Views/ABSBrowseView.swift`
- `Echo macOS/Views/MacAudiobookshelfView.swift`
- `Echo.xcodeproj/project.pbxproj` only if synchronized-group membership requires an exact target exclusion.
- `ARCHITECTURE.md` and `CHANGELOG.md`.

New tests:

- `EchoTests/ABSBrowseQueryTests.swift`
- `EchoTests/ABSBrowseOrderingTests.swift`
- `EchoTests/ABSLocalImportStatusTests.swift`
- `EchoTests/ABSBrowseModelTests.swift`
- `EchoTests/ABSDownloadProgressTests.swift`
- `EchoTests/ABSImportProgressTests.swift`
- `EchoTests/ABSBrowseViewWiringTests.swift`

Existing test suites modified: `AudiobookshelfServiceLibraryTests`, `AudiobookshelfServiceDownloadTests`, `ABSImportServiceTests`, and `MacAudiobookshelfParityTests`.

---

### Task 1: Add Explicit Audiobookshelf Browse Query Contracts

**Files:**
- Create: `EchoCore/Services/Audiobookshelf/ABSBrowseTypes.swift`
- Modify: `EchoCore/Services/Audiobookshelf/ABSModels.swift`
- Modify: `EchoCore/Services/Audiobookshelf/ABSEndpoints.swift`
- Modify: `EchoCore/Services/Audiobookshelf/AudiobookshelfService.swift`
- Create: `EchoTests/ABSBrowseQueryTests.swift`
- Modify: `EchoTests/AudiobookshelfServiceLibraryTests.swift`

**Interfaces:**
- Produces: `ABSBrowseSort`, `ABSFilterGroup`, `ABSFilterOption`, `ABSFilterSelection`, `ABSLibraryItemsQuery`, `ABSLibraryFilterData`, query-aware item methods, and `libraryFilterData(libraryID:)`.
- Consumes: existing ABS response models, authorized requests, and `URLProtocolStub`.

- [ ] **Step 1: Write failing query and decoding tests**

```swift
@MainActor
@Suite struct ABSBrowseQueryTests {
    @Test func newestUsesAddedAtDescending() {
        let query = ABSLibraryItemsQuery(sort: .newestAdded)
        #expect(query.sortField == "addedAt")
        #expect(query.descending)
    }

    @Test func authorFilterUsesGroupDotBase64() {
        let option = ABSFilterOption(
            group: .authors,
            value: "aut_z3leimgybl7uf3y4ab",
            label: "Terry Goodkind")
        #expect(option.encodedFilter == "authors.YXV0X3ozbGVpbWd5Ymw3dWYzeTRhYg==")
    }

    @Test func decodesAddedAtAndSeriesSequence() throws {
        let data = Data(#"{"id":"i1","libraryId":"l1","addedAt":1650621073750,"media":{"metadata":{"title":"Book","series":[{"name":"Saga","sequence":"2"}]}}}"#.utf8)
        let item = try JSONDecoder().decode(ABSLibraryItem.self, from: data)
        #expect(item.addedAt == 1_650_621_073_750)
        #expect(item.seriesName == "Saga")
        #expect(item.seriesSequence == "2")
    }
}
```

Extend `AudiobookshelfServiceLibraryTests` with `/api/libraries/lib1?include=filterdata` and assert authors, series, genres, and tags decode.

- [ ] **Step 2: Verify the tests fail before implementation**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
```

Expected: build fails because the new query/filter symbols and timestamp fields do not exist.

- [ ] **Step 3: Implement browse types and decoding**

```swift
enum ABSBrowseSort: String, CaseIterable, Codable, Sendable {
    case newestAdded, title, author, series, publicationYear

    var serverField: String? {
        switch self {
        case .newestAdded: "addedAt"
        case .title: "media.metadata.title"
        case .author: "media.metadata.authorName"
        case .series: nil
        case .publicationYear: "media.metadata.publishedYear"
        }
    }

    var descending: Bool { self == .newestAdded || self == .publicationYear }
}

enum ABSFilterGroup: String, CaseIterable, Codable, Sendable {
    case authors, series, genres, tags
}

struct ABSFilterOption: Identifiable, Hashable, Sendable {
    let group: ABSFilterGroup
    let value: String
    let label: String
    var id: String { "\(group.rawValue):\(value)" }
    var encodedFilter: String {
        "\(group.rawValue).\(Data(value.utf8).base64EncodedString())"
    }
}

struct ABSFilterSelection: Equatable, Sendable {
    var options: Set<ABSFilterOption> = []
    var notAddedOnly = false
}

struct ABSLibraryFilterData: Equatable, Sendable {
    let authors: [ABSFilterOption]
    let series: [ABSFilterOption]
    let genres: [ABSFilterOption]
    let tags: [ABSFilterOption]
    static let empty = ABSLibraryFilterData(
        authors: [], series: [], genres: [], tags: [])
}

struct ABSLibraryItemsQuery: Equatable, Sendable {
    var page = 0
    var limit = 100
    var sort: ABSBrowseSort = .newestAdded
    var filter: ABSFilterOption?
    var sortField: String? { sort.serverField }
    var descending: Bool { sort.descending }
}
```

Decode `ABSLibraryItem.addedAt: Int64?`, `seriesName`, and first-series `seriesSequence`, while preserving existing convenience properties. Add the `{ "filterdata": ... }` response with ID/name author/series values and genre/tag strings.

- [ ] **Step 4: Parameterize endpoint and service methods**

Implement:

```swift
func items(libraryID: String, query: ABSLibraryItemsQuery) -> URL
func libraryFilterData(_ libraryID: String) -> URL

func items(libraryID: String, query: ABSLibraryItemsQuery) async throws
    -> ABSLibraryItemsResponse
func allItems(libraryID: String, query: ABSLibraryItemsQuery) async throws
    -> [ABSLibraryItem]
func libraryFilterData(libraryID: String) async throws -> ABSLibraryFilterData
```

The items URL includes `page`, `limit`, `minified=0`, optional `sort`, `desc=1|0`, and optional `filter`. Give current iOS/macOS call sites `ABSLibraryItemsQuery(sort: .title)` until Task 4 replaces their state.

- [ ] **Step 5: Build and run focused tests**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ABSBrowseQueryTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/AudiobookshelfServiceLibraryTests
```

Expected: both suites pass.

- [ ] **Step 6: Commit**

```bash
git add EchoCore/Services/Audiobookshelf/ABSBrowseTypes.swift EchoCore/Services/Audiobookshelf/ABSModels.swift EchoCore/Services/Audiobookshelf/ABSEndpoints.swift EchoCore/Services/Audiobookshelf/AudiobookshelfService.swift EchoCore/Views/ABSBrowseView.swift 'Echo macOS/Views/MacAudiobookshelfView.swift' EchoTests/ABSBrowseQueryTests.swift EchoTests/AudiobookshelfServiceLibraryTests.swift
git commit -m "feat(abs): add browse query contracts"
```

---

### Task 2: Make Complete-Result Filtering and Ordering Deterministic

**Files:**
- Modify: `EchoCore/Services/Audiobookshelf/ABSBrowseTypes.swift`
- Create: `EchoTests/ABSBrowseOrderingTests.swift`

**Interfaces:**
- Produces: `ABSBrowseResultResolver.combinedIDs(filteredBy:)` and `sorted(_:by:)`.
- Consumes: decoded ABS items and grouped server query results.

- [ ] **Step 1: Write failing set-algebra and ordering tests**

```swift
@Suite struct ABSBrowseOrderingTests {
    @Test func unionsInsideCategoryAndIntersectsCategories() {
        let groups: [ABSFilterGroup: [[String]]] = [
            .authors: [["a", "b"], ["b", "c"]],
            .genres: [["b", "d"]],
        ]
        #expect(ABSBrowseResultResolver.combinedIDs(filteredBy: groups) == ["b"])
    }

    @Test func seriesUsesNameNumericSequenceThenTitle() throws {
        let sorted = ABSBrowseResultResolver.sorted(
            try ABSBrowseOrderingFixture.items(), by: .series)
        #expect(sorted.map(\.id) == ["saga-2", "saga-10", "saga-missing", "standalone"])
    }
}
```

Build fixture items through JSON decoding, including sequences `"2"` and `"10"`, a missing sequence, and a standalone book.

Create this private fixture contract in the test file; its JSON array supplies those four cases:

```swift
private enum ABSBrowseOrderingFixture {
    static func items() throws -> [ABSLibraryItem] {
        let data = Data(Self.json.utf8)
        return try JSONDecoder().decode([ABSLibraryItem].self, from: data)
    }
    private static let json = """
        [
          {"id":"saga-10","libraryId":"l1","media":{"metadata":{"title":"Ten","series":[{"name":"Saga","sequence":"10"}]}}},
          {"id":"standalone","libraryId":"l1","media":{"metadata":{"title":"Alone"}}},
          {"id":"saga-2","libraryId":"l1","media":{"metadata":{"title":"Two","series":[{"name":"Saga","sequence":"2"}]}}},
          {"id":"saga-missing","libraryId":"l1","media":{"metadata":{"title":"Unknown","series":[{"name":"Saga"}]}}}
        ]
        """
}
```

Include `saga-missing` in the expected order after `saga-10` and before `standalone`.

- [ ] **Step 2: Verify the resolver is missing**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
```

Expected: build fails on `ABSBrowseResultResolver`.

- [ ] **Step 3: Implement pure result resolution**

```swift
enum ABSBrowseResultResolver {
    nonisolated static func combinedIDs(
        filteredBy groups: [ABSFilterGroup: [[String]]]
    ) -> Set<String>

    nonisolated static func sorted(
        _ items: [ABSLibraryItem], by sort: ABSBrowseSort
    ) -> [ABSLibraryItem]
}
```

Union selection results within each group and intersect group unions. De-duplicate by remote ID. Series ordering is localized series name, numeric `Double` sequence, then title; missing/unparseable sequences follow numeric values, standalone books follow series books, and item ID is the deterministic final tie-break. Implement matching local fallbacks for the other sort cases because filtered/search result sets are complete before local ordering.

- [ ] **Step 4: Build and test**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ABSBrowseOrderingTests
```

Expected: suite passes.

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Audiobookshelf/ABSBrowseTypes.swift EchoTests/ABSBrowseOrderingTests.swift
git commit -m "feat(abs): resolve complete browse filters and ordering"
```

---

### Task 3: Resolve Locally Usable Imports by Provenance

**Files:**
- Modify: `Shared/Database/DAOs/AudiobookDAO.swift`
- Create: `EchoCore/Services/Audiobookshelf/ABSImportProgress.swift`
- Create: `EchoTests/ABSLocalImportStatusTests.swift`

**Interfaces:**
- Produces: `AudiobookDAO.audiobookshelfRecords(serverID:)`, `ABSImportedBook`, and `ABSLocalImportStatus`.
- Consumes: `AudiobookRecord`, `PlaylistManager.audioExtensions`, and `PlaylistManager.documentExtensions`.

- [ ] **Step 1: Write a failing provenance/filesystem test**

```swift
@MainActor
@Suite(.serialized) struct ABSLocalImportStatusTests {
    @Test func returnsOnlyUsableRecordsForActiveServer() throws {
        let db = try DatabaseService(inMemory: ())
        let fixture = try ABSLocalImportFixture(db: db)
        defer { fixture.cleanUp() }
        try fixture.insertRecords()
        let records = try AudiobookDAO(db: db.writer)
            .audiobookshelfRecords(serverID: "server-a")
        let books = ABSLocalImportStatus.usableBooks(records: records)
        #expect(Set(books.map(\.remoteItemID)) == ["usable"])
    }
}
```

The fixture includes root `book.m4b`, missing-folder, cover-only, nested-only audio, another-server, and non-ABS records.

Create a private `ABSLocalImportFixture` with this exact interface:

```swift
private final class ABSLocalImportFixture {
    init(db: DatabaseService) throws
    func insertRecords() throws
    func cleanUp()
}
```

Its initializer creates explicit temporary managed-folder URLs, `insertRecords` saves the six records listed above through `AudiobookDAO`, and `cleanUp` removes only those fixture directories.

- [ ] **Step 2: Verify the new API is absent**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
```

Expected: build fails on the DAO/status types.

- [ ] **Step 3: Implement parameterized lookup and usable-book contracts**

```swift
func audiobookshelfRecords(serverID: String) throws -> [AudiobookRecord] {
    try db.read { database in
        try AudiobookRecord
            .filter(Column("source_type") == "audiobookshelf")
            .filter(Column("server_id") == serverID)
            .filter(Column("remote_item_id") != nil)
            .fetchAll(database)
    }
}

struct ABSImportedBook: Identifiable, Equatable, Sendable {
    let remoteItemID: String
    let folderURL: URL
    let title: String
    var id: String { remoteItemID }
}
```

Implement `ABSLocalImportStatus.hasSupportedRootContent(at:)` and `usableBooks(records:)`. Root-only checking intentionally mirrors the actual player/document folder load; nested-only content is not usable success.

- [ ] **Step 4: Build and test**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ABSLocalImportStatusTests
```

Expected: suite passes.

- [ ] **Step 5: Commit**

```bash
git add Shared/Database/DAOs/AudiobookDAO.swift EchoCore/Services/Audiobookshelf/ABSImportProgress.swift EchoTests/ABSLocalImportStatusTests.swift
git commit -m "feat(abs): resolve locally added books by provenance"
```

---

### Task 4: Build the Shared Browse Model

**Files:**
- Create: `EchoCore/ViewModels/ABSBrowseModel.swift`
- Create: `EchoTests/ABSBrowseModelTests.swift`

**Interfaces:**
- Produces: `ABSBrowseModel` browse state and `load`, `selectLibrary`, `setSort`, `toggleFilter`, `setNotAddedOnly`, `clearFilters`, `setSearchQuery`, `refresh`, and `loadNextPageIfNeeded`.
- Consumes: query-aware service, provenance DAO/status, and result resolver.

- [ ] **Step 1: Write failing model tests using a real service and in-memory DB**

```swift
@MainActor
@Suite(.serialized) struct ABSBrowseModelTests {
    @Test func defaultsToNewestDescending() async throws {
        let fixture = try ABSBrowseModelFixture()
        fixture.stubLibrariesAndEmptyItems()
        await fixture.model.load()
        let request = try #require(URLProtocolStub.requests.last)
        let query = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)
        #expect(query?.queryItems?.contains(.init(name: "sort", value: "addedAt")) == true)
        #expect(query?.queryItems?.contains(.init(name: "desc", value: "1")) == true)
    }

    @Test func notAddedRemovesUsableBook() async throws {
        let fixture = try ABSBrowseModelFixture(importedRemoteID: "i1")
        fixture.stubLibraryItems(ids: ["i1", "i2"])
        await fixture.model.load()
        fixture.model.setNotAddedOnly(true)
        #expect(fixture.model.displayedItems.map(\.id) == ["i2"])
    }
}
```

Also test persisted sort, multiple-filter fan-out, stale request rejection, page append without clearing prior rows, refresh preserving query/sort/filters, search cancellation, filter reset on library change, result totals, and limited-search labeling. Inject debounce duration `0` in tests.

Create one private fixture with this exact interface so every test uses the real concrete service:

```swift
@MainActor
private final class ABSBrowseModelFixture {
    let db: DatabaseService
    let service: AudiobookshelfService
    let model: ABSBrowseModel
    let item: ABSLibraryItem

    init(
        importedRemoteID: String? = nil,
        importZipEntry: String? = nil
    ) throws
    func stubLibrariesAndEmptyItems()
    func stubLibraryItems(ids: [String])
}
```

The initializer uses `URLProtocolStub.makeSession()`, a unique token-store server ID, an in-memory database, and `debounce: .zero`. When `importedRemoteID` is present it creates a managed folder with `book.m4b` and saves matching provenance. When `importZipEntry` is present it stubs a ZIP download containing that entry.

- [ ] **Step 2: Verify the model is absent**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
```

Expected: build fails on `ABSBrowseModel`.

- [ ] **Step 3: Implement observable state and generation cancellation**

```swift
@MainActor @Observable
final class ABSBrowseModel {
    enum LoadState: Equatable { case idle, loading, loaded, failed(String) }

    private let service: AudiobookshelfService
    private let db: DatabaseService
    let serverID: String
    var libraries: [ABSLibrary] = []
    var selectedLibraryID: String?
    var items: [ABSLibraryItem] = []
    var displayedItems: [ABSLibraryItem] = []
    var filterData = ABSLibraryFilterData.empty
    var selection = ABSFilterSelection()
    var sort: ABSBrowseSort
    var searchQuery = ""
    var totalCount: Int?
    var searchResultsAreLimited = false
    var loadState: LoadState = .idle
    var isLoadingNextPage = false
    private(set) var addedBooksByRemoteID: [String: ABSImportedBook] = [:]

    init(
        service: AudiobookshelfService,
        db: DatabaseService,
        serverID: String,
        debounce: Duration = .milliseconds(300)
    )
}
```

Own one browse task and monotonically increasing generation. Every library/sort/filter change cancels and replaces it; responses check cancellation and generation before state mutation. Persist sort raw value under `absBrowseSort`, default Newest Added, and clear metadata selections when switching libraries.

- [ ] **Step 4: Implement complete query/filter/search behavior**

With zero metadata selections, page normally. With one, use one server filter. With multiple, load all pages for each option with at most four option queries in flight, combine complete ID sets, then sort. Series sort loads every page before publishing. Apply Not Added after server results. Search debounces, requests `searchLimit = 10_000`, intersects active filter IDs, and sets `searchResultsAreLimited` when the server returns exactly that cap.

- [ ] **Step 5: Build and test**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ABSBrowseModelTests
```

Expected: suite passes without real-time sleeps.

- [ ] **Step 6: Commit**

```bash
git add EchoCore/ViewModels/ABSBrowseModel.swift EchoTests/ABSBrowseModelTests.swift
git commit -m "feat(abs): add shared browse model"
```

---

### Task 5: Stream Real Download Progress Without Weakening Trust

**Files:**
- Modify: `EchoCore/Services/Audiobookshelf/ABSImportProgress.swift`
- Modify: `EchoCore/Services/Audiobookshelf/AudiobookshelfService.swift`
- Create: `EchoTests/ABSDownloadProgressTests.swift`
- Modify: `EchoTests/AudiobookshelfServiceDownloadTests.swift`

**Interfaces:**
- Produces: `ABSDownloadProgress` and `downloadItemZip(itemID:to:onProgress:)`.
- Consumes: existing service session, Bearer/refresh flow, and session-level certificate-pinning delegate.

- [ ] **Step 1: Write failing known-length, unknown-length, retry, and cancellation tests**

```swift
@MainActor
@Suite struct ABSDownloadProgressTests {
    @Test func knownLengthEndsAtOneHundredPercent() async throws {
        let fixture = ABSDownloadFixture(headers: ["Content-Length": "1024"])
        var updates: [ABSDownloadProgress] = []
        try await fixture.service.downloadItemZip(
            itemID: "i1", to: fixture.destination,
            onProgress: { updates.append($0) })
        #expect(updates.map(\.bytesReceived) == updates.map(\.bytesReceived).sorted())
        #expect(updates.last?.totalBytes == 1024)
        #expect(updates.last?.fractionCompleted == 1)
    }
}
```

Unknown length ends with `totalBytes == nil` and received bytes. A 401/refresh retry resets its attempt counter. Cancellation throws `CancellationError` and leaves no destination.

Create `ABSDownloadFixture` with `service`, explicit temporary `destination`, and cleanup; its initializer resets `URLProtocolStub`, supplies the requested headers and a 1024-byte payload, and gives the token store an access token.

- [ ] **Step 2: Verify the overload is absent**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
```

Expected: build fails on progress symbols.

- [ ] **Step 3: Implement sendable progress and a per-download delegate**

```swift
struct ABSDownloadProgress: Equatable, Sendable {
    let bytesReceived: Int64
    let totalBytes: Int64?
    var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(bytesReceived) / Double(totalBytes))
    }
}

func downloadItemZip(
    itemID: String,
    to destination: URL,
    onProgress: @escaping @MainActor @Sendable (ABSDownloadProgress) -> Void
) async throws
```

Add a private `NSObject, URLSessionDownloadDelegate, @unchecked Sendable` that yields `ABSDownloadProgress` through an `AsyncStream` continuation and finishes it from `didCompleteWithError`. Start `session.download(for:request, delegate:delegate)` in a child task, consume the stream inside the service's Main Actor isolation, call an `@MainActor @Sendable` progress closure, then await the download result. Keep the service's existing session-level `ABSServerTrustDelegate`; never create an unpinned replacement session. Normalize `NSURLSessionTransferSizeUnknown` and non-positive totals to nil and emit a final update after moving the temp file.

Wrap the stream consumption/result await in `withTaskCancellationHandler`; its cancellation handler cancels the child download task so view/model cancellation reaches `URLSession` immediately.

- [ ] **Step 4: Preserve refresh and cleanup semantics**

Use a fresh task delegate after a 401 refresh so attempt progress restarts. Map URL cancellation to `CancellationError`. Remove unsuccessful staging files, not a previously completed ABS library folder.

- [ ] **Step 5: Build and run download tests**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ABSDownloadProgressTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/AudiobookshelfServiceDownloadTests
```

Expected: both suites pass, including existing header-auth/no-query-token checks.

- [ ] **Step 6: Commit**

```bash
git add EchoCore/Services/Audiobookshelf/ABSImportProgress.swift EchoCore/Services/Audiobookshelf/AudiobookshelfService.swift EchoTests/ABSDownloadProgressTests.swift EchoTests/AudiobookshelfServiceDownloadTests.swift
git commit -m "feat(abs): report audiobook download progress"
```

---

### Task 6: Make Import Stages Observable and Success Verifiable

**Files:**
- Modify: `EchoCore/Services/Audiobookshelf/ABSImportProgress.swift`
- Modify: `EchoCore/Services/Audiobookshelf/ABSImportService.swift`
- Modify: `EchoTests/ABSImportServiceTests.swift`
- Create: `EchoTests/ABSImportProgressTests.swift`

**Interfaces:**
- Produces: `ABSImportStage`, `ABSImportProgress`, `ABSImportFailure`, and result-returning `prepareLocalFolder`.
- Consumes: progress download, ZIP entries, atomic replacement, local content status, and provenance DAO.

- [ ] **Step 1: Write failing stage, validation, cancellation, and rollback tests**

```swift
@MainActor
@Suite(.serialized) struct ABSImportProgressTests {
    @Test func successReportsStagesAndReturnsUsableBook() async throws {
        let fixture = try ABSImportProgressFixture(zipEntry: "book.m4b")
        var updates: [ABSImportProgress] = []
        let book = try await fixture.importer.prepareLocalFolder(
            for: fixture.item, onProgress: { updates.append($0) })
        let stages = updates.map(\.stage)
        let indices = [
            ABSImportStage.downloading, .extracting, .validating, .addingToEcho, .added
        ].compactMap { stages.firstIndex(of: $0) }
        #expect(indices.count == 5)
        #expect(indices == indices.sorted())
        #expect(book.remoteItemID == fixture.item.id)
        #expect(ABSLocalImportStatus.hasSupportedRootContent(at: book.folderURL))
    }

    @Test func nestedOnlyAudioFailsValidation() async throws {
        let fixture = try ABSImportProgressFixture(zipEntry: "wrapper/book.m4b")
        await #expect(throws: ABSImportFailure.self) {
            try await fixture.importer.prepareLocalFolder(for: fixture.item) { _ in }
        }
    }
}
```

Also assert monotonic extraction, corrupt ZIP stage, cancellation cleanup, DB failure stage, and preservation of an existing completed re-import.

Create `ABSImportProgressFixture` with `db`, `service`, `importer`, `item`, and cleanup. Its `init(zipEntry:)` builds a one-entry ZIP using ZIPFoundation, stubs `/download`, and constructs the real concrete import service with an in-memory database.

- [ ] **Step 2: Verify stage contracts are absent**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
```

Expected: build fails on stage/progress/failure APIs.

- [ ] **Step 3: Define import contracts**

```swift
enum ABSImportStage: String, Equatable, Sendable {
    case downloading, extracting, validating, addingToEcho, added
}

struct ABSImportProgress: Equatable, Sendable {
    let stage: ABSImportStage
    let completedUnits: Int64
    let totalUnits: Int64?
}

struct ABSImportFailure: LocalizedError, Equatable, Sendable {
    let stage: ABSImportStage
    let message: String
    let isRetryable: Bool
    var errorDescription: String? { message }
}
```

- [ ] **Step 4: Thread stages and cancellation through import**

```swift
func prepareLocalFolder(
    for item: ABSLibraryItem,
    onProgress: @escaping @MainActor @Sendable (ABSImportProgress) -> Void = { _ in }
) async throws -> ABSImportedBook
```

Forward transport bytes as Downloading. Sum safe entry sizes after existing archive limits; report Extracting after each file, falling back to file count. The nonisolated extraction function accepts the same `@MainActor @Sendable` callback and uses `await onProgress(...)`, keeping filesystem work off the UI actor while serializing state updates safely. Check cancellation before and after each entry. Report Validating and require supported root content. Report Adding to Echo, atomically publish/save, re-read provenance, resolve through `ABSLocalImportStatus`, then report Added and return the resolved book.

- [ ] **Step 5: Add privacy-safe telemetry**

Use logger category `AudiobookshelfImport`. Log stage, hashed/private remote item ID, HTTP/local error category, bytes, and whether total is known. Never interpolate title, author, filesystem path, server URL/body, credentials, or tokens.

- [ ] **Step 6: Build and run import tests**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ABSImportProgressTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ABSImportServiceTests
```

Expected: both suites pass, including existing size-limit, zip-slip, cover, atomic replacement, and residue tests.

- [ ] **Step 7: Commit**

```bash
git add EchoCore/Services/Audiobookshelf/ABSImportProgress.swift EchoCore/Services/Audiobookshelf/ABSImportService.swift EchoTests/ABSImportProgressTests.swift EchoTests/ABSImportServiceTests.swift
git commit -m "fix(abs): verify staged audiobook imports"
```

---

### Task 7: Integrate Import State into the Shared Model

**Files:**
- Modify: `EchoCore/ViewModels/ABSBrowseModel.swift`
- Modify: `EchoTests/ABSBrowseModelTests.swift`

**Interfaces:**
- Produces: `ImportState`, `importState(for:)`, `add(_:)`, `cancelImport()`, `retryImport(_:)`, and `openTarget(for:)`.
- Consumes: staged import service and imported-book result.

- [ ] **Step 1: Add failing model state-machine tests**

```swift
@MainActor
@Test func successRetainsAddedStateAndOpenTarget() async throws {
    let fixture = try ABSBrowseModelFixture(importZipEntry: "book.m4b")
    await fixture.model.add(fixture.item)
    guard case .added(let book) = fixture.model.importState(for: fixture.item.id) else {
        Issue.record("Expected Added state")
        return
    }
    #expect(fixture.model.openTarget(for: fixture.item.id) == book)
    #expect(fixture.model.displayedItems.contains { $0.id == fixture.item.id })
}
```

Also test one import at a time, stage mapping, cancel, named failure retention, retry reset, and immediate removal under Not Added.

- [ ] **Step 2: Verify model import APIs are absent**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
```

Expected: build fails on import-state APIs.

- [ ] **Step 3: Implement the state machine**

```swift
extension ABSBrowseModel {
    enum ImportState: Equatable {
        case ready
        case running(ABSImportProgress, startedAt: Date)
        case failed(ABSImportFailure)
        case added(ABSImportedBook)
    }
}
```

Own one import task and active item ID. Apply the already Main-Actor-isolated progress callbacks directly and in order. Success updates local provenance and retained Added state; failure remains visible; cancellation becomes retryable. Other Add controls remain disabled while the task exists.

- [ ] **Step 4: Build and test**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ABSBrowseModelTests
```

Expected: all browse/import model tests pass.

- [ ] **Step 5: Commit**

```bash
git add EchoCore/ViewModels/ABSBrowseModel.swift EchoTests/ABSBrowseModelTests.swift
git commit -m "feat(abs): retain observable import state"
```

---

### Task 8: Bind iOS to the Shared Model

**Files:**
- Modify: `EchoCore/ViewModels/PlayerModel+Audiobookshelf.swift`
- Modify: `EchoCore/Views/ABSConnectionsSettingsView.swift`
- Modify: `EchoCore/Views/ABSBrowseView.swift`
- Create: `EchoTests/ABSBrowseViewWiringTests.swift`

**Interfaces:**
- Produces: `makeABSBrowseModel`, `openAudiobookshelfBook`, `ABSImportPresentation.progressLabel(completed:total:)`, and native iOS sort/filter/progress UI.
- Consumes: shared browse/import model.

- [ ] **Step 1: Write failing wiring and presentation tests**

```swift
@Suite struct ABSBrowseViewWiringTests {
    @Test func iOSUsesSharedModelAndDoesNotDismissOnSuccess() throws {
        let source = try EchoSource.read("Views/ABSBrowseView.swift")
        #expect(source.contains("ABSBrowseModel"))
        #expect(source.contains("Open in Echo"))
        #expect(!source.contains("onImported: { dismiss() }"))
    }

    @Test func progressCopyDistinguishesUnknownTotal() {
        #expect(ABSImportPresentation.progressLabel(completed: 512, total: 1024).contains("50%"))
        #expect(!ABSImportPresentation.progressLabel(completed: 512, total: nil).contains("%"))
    }
}
```

Implement `EchoSource` using the source-file lookup pattern in `ABSImportServiceTests` if no shared helper exists.

Use this test-local contract:

```swift
private enum EchoSource {
    static func read(_ relativePath: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.deletingLastPathComponent()
                .appending(path: "EchoCore/\(relativePath)")
            if let source = try? String(contentsOf: candidate, encoding: .utf8) {
                return source
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
```

- [ ] **Step 2: Verify wiring tests fail**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
```

Expected: missing shared wiring/presentation helpers.

- [ ] **Step 3: Inject model from Connections**

```swift
func makeABSBrowseModel() -> ABSBrowseModel? {
    guard let service = makeAudiobookshelfService(),
          let db = databaseService,
          let serverID = absServiceServerID ?? (try? absServerDAO?.current())?.id
    else { return nil }
    return ABSBrowseModel(service: service, db: db, serverID: serverID)
}

func openAudiobookshelfBook(_ book: ABSImportedBook) {
    loadFolder(book.folderURL, autoplay: false)
    selectedTab = .nowPlaying
}
```

Connections constructs the model when Browse Library is tapped. Construction failure stays on Connections and uses its error section.

- [ ] **Step 4: Render iOS browse organization**

Refactor `ABSBrowseView` to own the injected shared model. Add toolbar Sort, Filters sheet with searchable Author/Series/Genre/Tag multi-select, Not Added, active count, Clear Filters, result count, limited-search wording, Added badges, next-page trigger that retains existing rows, refresh that preserves the active query, and distinct empty-library/no-search/no-filter/no-not-added states. Localize strings and add accessibility values for sort/filter count.

Add this pure formatter beside the private view helpers so tests can pin known/unknown total wording:

```swift
enum ABSImportPresentation {
    static func progressLabel(completed: Int64, total: Int64?) -> String {
        let completedText = ByteCountFormatter.string(fromByteCount: completed, countStyle: .file)
        guard let total, total > 0 else { return completedText }
        let percent = Int((Double(completed) / Double(total) * 100).rounded())
        let totalText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return String(localized: "\(percent)% · \(completedText) of \(totalText)")
    }
}
```

- [ ] **Step 5: Render staged import without success dismissal**

Use model add/cancel/retry. Display stage, elapsed time, bytes, determinate progress only with a known total, and indeterminate progress otherwise. Failure shows stage/message/Retry. Added shows Open in Echo. Only that explicit action opens and dismisses. Add accessibility labels/values for stage, byte progress, completion, sort, and filter count.

- [ ] **Step 6: Build and run iOS-focused suites**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ABSBrowseViewWiringTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ABSBrowseModelTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ABSImportProgressTests
```

Expected: suites pass. If synchronized target membership fails, add only the exact new incompatible file to the affected target's `membershipExceptions` and rebuild.

- [ ] **Step 7: Commit**

```bash
git add EchoCore/ViewModels/PlayerModel+Audiobookshelf.swift EchoCore/Views/ABSConnectionsSettingsView.swift EchoCore/Views/ABSBrowseView.swift EchoTests/ABSBrowseViewWiringTests.swift Echo.xcodeproj/project.pbxproj
git commit -m "feat(abs): add organized reliable iOS browsing"
```

---

### Task 9: Bind macOS to the Shared Model

**Files:**
- Create: `Echo macOS/Views/MacAudiobookshelfBrowseView.swift`
- Modify: `Echo macOS/Views/MacAudiobookshelfView.swift`
- Modify: `EchoTests/MacAudiobookshelfParityTests.swift`

**Interfaces:**
- Produces: matching macOS controls and explicit Open behavior.
- Consumes: shared model, active service/server/database, and existing `onPlay(URL)`.

- [ ] **Step 1: Replace obsolete Mac browse assertions with failing parity assertions**

```swift
@Test func browseUsesSharedStateAndRetainsSuccess() throws {
    let host = try MacSource.read("Views/MacAudiobookshelfView.swift")
    let browse = try MacSource.read("Views/MacAudiobookshelfBrowseView.swift")
    #expect(host.contains("ABSBrowseModel("))
    #expect(browse.contains("Open in Echo"))
    #expect(browse.contains("Clear Filters"))
    #expect(!browse.contains("if await model.addToLibrary(item) { dismiss() }"))
}
```

Retain connection, trust, switching, and progress-sync tests.

- [ ] **Step 2: Verify the new Mac view is absent**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
```

Expected: new view lookup/parity assertion fails.

- [ ] **Step 3: Separate connection ownership from browsing**

Keep `MacAudiobookshelfViewModel` responsible for saved servers, connect, sign-out, switch, trust confirmation, and service lifetime. Replace duplicated browse/search/import properties with:

```swift
var browseModel: ABSBrowseModel?

private func installBrowseModel(service: AudiobookshelfService, serverID: String) {
    browseModel = ABSBrowseModel(service: service, db: db, serverID: serverID)
}
```

Install/load after active-server load, connect, and switch; clear when removing the active server.

- [ ] **Step 4: Build native macOS presentation**

Add Library, Sort, Filters with count, Search, and result count. Use popover/compact sheet filters with matching labels. Use list/detail presentation for stage, known/unknown byte progress, failure/Retry, Added, and Open. Success does not dismiss; explicit Open calls `onPlay(book.folderURL)` and may dismiss. Match iOS accessibility labels/values for stage, byte progress, completion, sort, and filter count.

- [ ] **Step 5: Build and run parity suites**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/MacAudiobookshelfParityTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ABSBrowseModelTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ABSBrowseViewWiringTests
```

Expected: all pass and existing connection/sync parity remains.

- [ ] **Step 6: Commit**

```bash
git add 'Echo macOS/Views/MacAudiobookshelfBrowseView.swift' 'Echo macOS/Views/MacAudiobookshelfView.swift' EchoTests/MacAudiobookshelfParityTests.swift
git commit -m "feat(abs): match organized macOS browsing"
```

---

### Task 10: Complete Regression Coverage, Documentation, and Acceptance

**Files:**
- Modify: `ARCHITECTURE.md`
- Modify: `CHANGELOG.md`
- Modify: in-scope source/tests only if final verification exposes a regression.

**Interfaces:**
- Produces: full verification, current documentation, live checklist, and ready PR.
- Consumes: completed implementation.

- [ ] **Step 1: Update documentation**

Update the Audiobookshelf architecture section with the shared model, server filter fan-out/set algebra, local series sort, provenance Added state, and verified import boundary. Add an unreleased changelog bullet covering sorts, filters, Not Added, transfer/import progress, retained failures, and Added/Open.

- [ ] **Step 2: Run formatting and residue checks**

```bash
git diff --check
rg -n "onImported: \{ dismiss\(\) \}|if await model\.addToLibrary\(item\) \{ dismiss\(\) \}" EchoCore 'Echo macOS'
rg -n "URLQueryItem\(name: \"sort\", value: \"media\.metadata\.title\"\)" EchoCore
```

Expected: diff is clean and searches find no automatic-success dismissal or hard-coded endpoint sort.

- [ ] **Step 3: Review telemetry for private data**

```bash
rg -n "logger\.|Logger\(" EchoCore/Services/Audiobookshelf/ABSImportService.swift EchoCore/Services/Audiobookshelf/ABSImportProgress.swift EchoCore/Services/Audiobookshelf/AudiobookshelfService.swift
```

Expected: import logs contain stage/category/byte evidence only; no titles, authors, paths, response bodies, server URLs, credentials, or tokens.

- [ ] **Step 4: Run all focused Audiobookshelf suites**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make build-tests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ABSBrowseQueryTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ABSBrowseOrderingTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ABSLocalImportStatusTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ABSBrowseModelTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ABSDownloadProgressTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/AudiobookshelfServiceDownloadTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ABSImportProgressTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ABSImportServiceTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/ABSBrowseViewWiringTests
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test-only FILTER=EchoTests/MacAudiobookshelfParityTests
```

Expected: every suite passes.

- [ ] **Step 5: Run the primary unit gate**

```bash
/Users/dfakkeldy/.claude/bin/xcode-build-slot.sh -- make test
```

Expected: `TEST SUCCEEDED` with no error output.

- [ ] **Step 6: Perform simulator smoke checks**

Using non-private fixture books, verify on iPhone Simulator and macOS: default Newest; all five sorts; author union plus author/genre intersection; Clear Filters; Not Added; known/unknown progress; forced HTTP and unsupported-archive retained failures; retained Added/Open; and explicit Open navigation. Record observations in the PR body, not committed screenshots.

- [ ] **Step 7: Perform owner-authorized live acceptance**

Against the owner's existing server, without recording credentials, private library metadata, or media: retry the reported failing title; observe bytes and stages; confirm retained failure or Added; confirm local Library presence; Open and load audio; repeat with a previously successful title; exercise author/series and genre/tag filters. If failure remains, capture only privacy-safe stage/error category and do not weaken acceptance.

- [ ] **Step 8: Commit documentation and in-scope final corrections**

```bash
git add ARCHITECTURE.md CHANGELOG.md
git commit -m "docs: record Audiobookshelf browse reliability"
```

If earlier commits left no correction, this commit contains only the two documentation files.

- [ ] **Step 9: Verify status and publish a ready PR**

```bash
git status --short --branch
git log --oneline nightly..HEAD
git push -u origin feature/abs-browse-import-reliability
gh pr create --base nightly --title "feat(abs): improve browsing and import reliability" --body-file /tmp/echo-abs-pr-body.md
```

Create `/tmp/echo-abs-pr-body.md` with user-visible changes, exact automated results, simulator status, live-server status, spec/plan links, and separate CI/merge/installation/device-acceptance states. Report hosted CI as passing, failing, pending, or blocked.
