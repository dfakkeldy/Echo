// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct LibraryServiceTests {
    private func fixedNow() -> String { "2026-06-27T00:00:00Z" }

    @Test func rescanInsertsShallowRowsForNewBooks() throws {
        let db = try DatabaseService(inMemory: ())
        let service = LibraryService(db: db)
        // Register a REAL temp dir so the bookmark resolves and rescan's
        // stale-bookmark guard passes. The injected discover ignores the resolved
        // URL and returns a fixed synthetic book, so id assertions stay deterministic.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lib-rescan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = try service.registerRoot(url: tmp, now: fixedNow)

        let discovered = [
            DiscoveredBook(
                folderURL: URL(fileURLWithPath: "/Lib/Dune", isDirectory: true),
                audioFiles: [URL(fileURLWithPath: "/Lib/Dune/d.m4b")], companionEPUB: nil)
        ]
        let result = try service.rescan(root: root, discover: { _ in discovered }, now: fixedNow)

        #expect(result.added == 1)
        let book = try AudiobookDAO(db: db.writer).get("file:///Lib/Dune/")
        #expect(book?.indexState == 0)
        #expect(book?.isAvailable == true)
        #expect(book?.sourceRootID == root.id)
    }

    @Test func rescanStartsSecurityScopeBeforeDiscovery() throws {
        // A sandbox-external root must have its security scope started before
        // enumeration, or discovery returns nothing and the whole shelf is
        // hidden. Assert the scope seam runs, and runs before discover.
        let db = try DatabaseService(inMemory: ())
        let service = LibraryService(db: db)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lib-rescan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = try service.registerRoot(url: tmp, now: fixedNow)

        var events: [String] = []
        _ = try service.rescan(
            root: root,
            discover: { _ in
                events.append("discover")
                return []
            },
            startScope: { _ in
                events.append("scope")
                return true
            },
            now: fixedNow)

        #expect(events == ["scope", "discover"])
    }

    @Test func rescanHidesBooksThatVanished() throws {
        let db = try DatabaseService(inMemory: ())
        let service = LibraryService(db: db)
        // Real temp dir so both rescans clear the stale-bookmark guard.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lib-rescan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = try service.registerRoot(url: tmp, now: fixedNow)
        let dune = DiscoveredBook(
            folderURL: URL(fileURLWithPath: "/Lib/Dune", isDirectory: true),
            audioFiles: [URL(fileURLWithPath: "/Lib/Dune/d.m4b")], companionEPUB: nil)

        _ = try service.rescan(root: root, discover: { _ in [dune] }, now: fixedNow)
        let result = try service.rescan(root: root, discover: { _ in [] }, now: fixedNow)

        #expect(result.hidden == 1)
        #expect(try AudiobookDAO(db: db.writer).get("file:///Lib/Dune/")?.isAvailable == false)
    }

    @Test func rescanStartsSecurityScopeAroundDiscovery() throws {
        let db = try DatabaseService(inMemory: ())
        let service = LibraryService(db: db)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lib-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = try service.registerRoot(url: tmp, now: fixedNow)
        var startedURL: URL?
        var stoppedURL: URL?
        var discoverSawScope = false

        _ = try service.rescan(
            root: root,
            discover: { url in
                discoverSawScope = startedURL == url
                return []
            },
            startScope: { url in
                startedURL = url
                return true
            },
            stopScope: { stoppedURL = $0 },
            now: fixedNow)

        #expect(discoverSawScope)
        #expect(stoppedURL == startedURL)
    }

    @Test func rescanAppliesInjectedMetadata() async throws {
        let db = try DatabaseService(inMemory: ())
        let service = LibraryService(db: db)
        // Correction B: register a REAL temp dir so the bookmark resolves and the
        // stale-bookmark guard passes. The injected discover ignores the resolved
        // URL and returns a fixed synthetic book, so id assertions stay deterministic.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lib-meta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = try service.registerRoot(url: tmp, now: fixedNow)

        let dune = DiscoveredBook(
            folderURL: URL(fileURLWithPath: "/Lib/Dune", isDirectory: true),
            audioFiles: [URL(fileURLWithPath: "/Lib/Dune/d.m4b")], companionEPUB: nil)
        let covers = FileManager.default.temporaryDirectory
            .appendingPathComponent("covers-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: covers) }

        _ = try await service.rescan(
            root: root,
            discover: { _ in [dune] },
            readMetadata: { _ in
                LibraryScanner.ScannedMetadata(
                    title: "Dune", author: "Tolkien, J.R.R.", narrator: "Scott Brick",
                    duration: 4242, coverImageData: Data([0xFF, 0xD8]))
            },
            coversDir: covers,
            now: fixedNow)

        let book = try AudiobookDAO(db: db.writer).get("file:///Lib/Dune/")
        #expect(book?.title == "Dune")
        #expect(book?.author == "Tolkien, J.R.R.")
        #expect(book?.narrator == "Scott Brick")
        #expect(book?.duration == 4242)
        #expect(book?.authorSort == "j.r.r. tolkien")
        #expect(book?.coverArtPath != nil)
    }

    @Test func metadataRescanBackfillsCoverFromCompanionEPUBWhenAudioHasNoCover() async throws {
        let db = try DatabaseService(inMemory: ())
        let service = LibraryService(db: db)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lib-epub-cover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = try service.registerRoot(url: tmp, now: fixedNow)

        let dune = DiscoveredBook(
            folderURL: URL(fileURLWithPath: "/Lib/Dune", isDirectory: true),
            audioFiles: [URL(fileURLWithPath: "/Lib/Dune/d.m4b")],
            companionEPUB: URL(fileURLWithPath: "/Lib/Dune/dune.epub"))
        let covers = FileManager.default.temporaryDirectory
            .appendingPathComponent("covers-epub-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: covers) }
        let coverData = Data([0xFF, 0xD8, 0xFF])

        _ = try await service.rescan(
            root: root,
            discover: { _ in [dune] },
            readMetadata: { _ in
                LibraryScanner.ScannedMetadata(
                    title: "Dune", author: "Frank Herbert", narrator: nil,
                    duration: 0, coverImageData: nil)
            },
            companionCoverData: { _ in coverData },
            coversDir: covers,
            now: fixedNow)

        let book = try #require(try AudiobookDAO(db: db.writer).get("file:///Lib/Dune/"))
        let coverPath = try #require(book.coverArtPath)
        #expect(try Data(contentsOf: covers.appendingPathComponent(coverPath)) == coverData)
    }

    @Test func metadataRescanStartsSecurityScopeAroundDiscovery() async throws {
        let db = try DatabaseService(inMemory: ())
        let service = LibraryService(db: db)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lib-meta-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = try service.registerRoot(url: tmp, now: fixedNow)
        let covers = FileManager.default.temporaryDirectory
            .appendingPathComponent("covers-scope-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: covers) }
        var startedURL: URL?
        var stoppedURL: URL?
        var discoverSawScope = false

        _ = try await service.rescan(
            root: root,
            discover: { url in
                discoverSawScope = startedURL == url
                return []
            },
            readMetadata: { _ in
                LibraryScanner.ScannedMetadata(
                    title: "Ignored", author: nil, narrator: nil,
                    duration: 0, coverImageData: nil)
            },
            coversDir: covers,
            startScope: { url in
                startedURL = url
                return true
            },
            stopScope: { stoppedURL = $0 },
            now: fixedNow)

        #expect(discoverSawScope)
        #expect(stoppedURL == startedURL)
    }

    @Test func rescanPreservesExistingMetadataWhenScannedIsNil() async throws {
        let db = try DatabaseService(inMemory: ())
        let service = LibraryService(db: db)
        // Real temp dir so the bookmark resolves and the stale-bookmark guard passes.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lib-coalesce-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = try service.registerRoot(url: tmp, now: fixedNow)

        // Pre-save a record with ABS-imported narrator/author/duration that the
        // scanner will NOT return (it returns nil narrator, nil author, 0 duration).
        let bookID = "file:///Lib/Dune/"
        let dao = AudiobookDAO(db: db.writer)
        var existing = AudiobookRecord(
            id: bookID, title: "Dune (pre)", author: "Frank Herbert", duration: 4242,
            fileCount: 1, addedAt: fixedNow(), isAvailable: true, sourceRootID: root.id)
        existing.narrator = "Scott Brick"
        try dao.save(existing)

        let dune = DiscoveredBook(
            folderURL: URL(fileURLWithPath: "/Lib/Dune", isDirectory: true),
            audioFiles: [URL(fileURLWithPath: "/Lib/Dune/d.m4b")], companionEPUB: nil)
        let covers = FileManager.default.temporaryDirectory
            .appendingPathComponent("covers-coalesce-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: covers) }

        _ = try await service.rescan(
            root: root,
            discover: { _ in [dune] },
            readMetadata: { _ in
                LibraryScanner.ScannedMetadata(
                    title: "Dune", author: nil, narrator: nil,
                    duration: 0, coverImageData: nil)
            },
            coversDir: covers,
            now: fixedNow)

        let book = try dao.get(bookID)
        // Title IS updated by rescan (scanner always returns a non-empty title).
        #expect(book?.title == "Dune")
        // narrator/author/duration must be PRESERVED (not wiped to nil/0).
        #expect(book?.narrator == "Scott Brick")
        #expect(book?.author == "Frank Herbert")
        #expect(book?.duration == 4242)
    }

    @Test func registerRootPersistsBookmarkAndRow() throws {
        let db = try DatabaseService(inMemory: ())
        let service = LibraryService(db: db)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lib-reg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let root = try service.registerRoot(url: tmp, now: fixedNow)
        #expect(try LibraryRootDAO(db: db.writer).get(root.id) != nil)
        #expect(root.bookmark.isEmpty == false)
    }

    @Test func booksHidesUnavailableByDefault() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = AudiobookDAO(db: db.writer)
        try dao.save(
            AudiobookRecord(
                id: "a", title: "A", author: nil, duration: 0, fileCount: nil,
                addedAt: "2026-06-27T00:00:00Z", isAvailable: true))
        try dao.save(
            AudiobookRecord(
                id: "b", title: "B", author: nil, duration: 0, fileCount: nil,
                addedAt: "2026-06-26T00:00:00Z", isAvailable: false))

        let service = LibraryService(db: db)
        #expect(try service.books(includeUnavailable: false).map(\.id) == ["a"])
        #expect(try service.books(includeUnavailable: true).map(\.id).sorted() == ["a", "b"])
    }

    @Test func sectionsByAuthorGroupOnNormalizedKey() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = AudiobookDAO(db: db.writer)
        try dao.save(
            AudiobookRecord(
                id: "1", title: "X", author: "Tolkien, J.R.R.", duration: 0, fileCount: nil,
                addedAt: "2026-06-27T00:00:00Z", isAvailable: true, authorSort: "j.r.r. tolkien"))
        try dao.save(
            AudiobookRecord(
                id: "2", title: "Y", author: "J.R.R. Tolkien", duration: 0, fileCount: nil,
                addedAt: "2026-06-26T00:00:00Z", isAvailable: true, authorSort: "j.r.r. tolkien"))

        let service = LibraryService(db: db)
        let sections = try service.sections(by: .author, includeUnavailable: false)
        #expect(sections.count == 1)
        #expect(sections.first?.books.count == 2)
    }

    @Test func sectionsByAuthorDerivesKeyWhenAuthorSortMissing() throws {
        // ABS / single-imported / pre-V27 books leave author_sort NULL; they
        // must still group by their distinct authors rather than collapsing
        // into one mislabeled "unknown" section.
        let db = try DatabaseService(inMemory: ())
        let dao = AudiobookDAO(db: db.writer)
        try dao.save(
            AudiobookRecord(
                id: "1", title: "Dune", author: "Frank Herbert", duration: 0,
                fileCount: nil, addedAt: "2026-06-27T00:00:00Z", isAvailable: true,
                authorSort: nil))
        try dao.save(
            AudiobookRecord(
                id: "2", title: "Left Hand", author: "Ursula K. Le Guin", duration: 0,
                fileCount: nil, addedAt: "2026-06-26T00:00:00Z", isAvailable: true,
                authorSort: nil))

        let service = LibraryService(db: db)
        let sections = try service.sections(by: .author, includeUnavailable: false)

        #expect(sections.map(\.title) == ["Frank Herbert", "Ursula K. Le Guin"])
        #expect(sections.map(\.books.count) == [1, 1])
    }

    @Test func booksCollapseEditionGroupsAndBorrowCoverFromTextEdition() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = AudiobookDAO(db: db.writer)
        try dao.save(
            AudiobookRecord(
                id: "audio", title: "Dune", author: "Frank Herbert", duration: 100,
                fileCount: 1, addedAt: "2026-07-05T00:00:00Z", isAvailable: true,
                editionGroupID: "edition-dune"))
        try dao.save(
            AudiobookRecord(
                id: "text", title: "Dune", author: "Frank Herbert", duration: 0,
                fileCount: 0, addedAt: "2026-07-05T00:00:01Z", coverArtPath: "dune.jpg",
                isAvailable: true, editionGroupID: "edition-dune"))

        let service = LibraryService(db: db)
        let books = try service.books(includeUnavailable: false)

        #expect(books.map(\.id) == ["audio"])
        #expect(books.first?.coverArtPath == "dune.jpg")
    }

    @Test func metadataRescanAssignsEditionGroupsToMatchingBooks() async throws {
        let db = try DatabaseService(inMemory: ())
        let service = LibraryService(db: db)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lib-editions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = try service.registerRoot(url: tmp, now: fixedNow)
        let dao = AudiobookDAO(db: db.writer)
        try dao.save(
            AudiobookRecord(
                id: "file:///Lib/DuneText/", title: "Dune", author: "Frank Herbert",
                duration: 0, fileCount: 0, addedAt: fixedNow(), isAvailable: true))

        let audio = DiscoveredBook(
            folderURL: URL(fileURLWithPath: "/Lib/DuneAudio", isDirectory: true),
            audioFiles: [URL(fileURLWithPath: "/Lib/DuneAudio/d.m4b")], companionEPUB: nil)

        _ = try await service.rescan(
            root: root,
            discover: { _ in [audio] },
            readMetadata: { _ in
                LibraryScanner.ScannedMetadata(
                    title: "The Dune", author: "Frank Herbert", narrator: nil,
                    duration: 100, coverImageData: nil)
            },
            coversDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("covers-editions-\(UUID().uuidString)", isDirectory: true),
            now: fixedNow)

        let text = try #require(try dao.get("file:///Lib/DuneText/"))
        let audioRecord = try #require(try dao.get("file:///Lib/DuneAudio/"))
        #expect(text.editionGroupID == audioRecord.editionGroupID)
        #expect(text.editionGroupID != nil)
    }

    // MARK: - Shelf-load regroup (edition unification)

    @Test func regroupForShelfLoadCollapsesSeparatelyImportedText() async throws {
        // The duplicate-card scenario: an m4b row (tagged) and a separately
        // imported epub row (author nil, no audio) never see a rescan, so only
        // the shelf-load regroup can pair them.
        let db = try DatabaseService(inMemory: ())
        let dao = AudiobookDAO(db: db.writer)
        try dao.save(
            AudiobookRecord(
                id: "file:///Lib/ShelfDuneAudio/", title: "Dune", author: "Frank Herbert",
                duration: 100, fileCount: 1, addedAt: "2026-07-10T00:00:00Z", isAvailable: true))
        try dao.save(
            AudiobookRecord(
                id: "file:///Lib/ShelfDuneText/", title: "Dune", author: nil,
                duration: 0, fileCount: 0, addedAt: "2026-07-10T00:00:01Z", isAvailable: true))

        // A fresh clock: the text row is minutes old, as it is in the real
        // scenario (regroup right after import) — an aged block-less text row
        // would be prunable junk instead.
        let now = try Date("2026-07-10T00:30:00Z", strategy: .iso8601)
        let service = LibraryService(db: db)
        let changed = await service.regroupForShelfLoad(now: { now })

        #expect(changed)
        let books = try service.books(includeUnavailable: false)
        #expect(books.map(\.id) == ["file:///Lib/ShelfDuneAudio/"])
        // Second pass with nothing new to do reports no changes.
        #expect(await service.regroupForShelfLoad(now: { now }) == false)
    }

    @Test func regroupForShelfLoadRespectsSeparatedEditionOptOut() async throws {
        let db = try DatabaseService(inMemory: ())
        let dao = AudiobookDAO(db: db.writer)
        try dao.save(
            AudiobookRecord(
                id: "file:///Lib/OptOutAudio/", title: "Dune", author: "Frank Herbert",
                duration: 100, fileCount: 1, addedAt: "2026-07-10T00:00:00Z", isAvailable: true))
        try dao.save(
            AudiobookRecord(
                id: "file:///Lib/OptOutText/", title: "Dune", author: nil,
                duration: 0, fileCount: 0, addedAt: "2026-07-10T00:00:01Z", isAvailable: true,
                editionGroupOptOut: true))

        let now = try Date("2026-07-10T00:30:00Z", strategy: .iso8601)
        let service = LibraryService(db: db)
        _ = await service.regroupForShelfLoad(now: { now })

        let books = try service.books(includeUnavailable: false)
        #expect(
            Set(books.map(\.id)) == ["file:///Lib/OptOutAudio/", "file:///Lib/OptOutText/"])
        #expect(try dao.get("file:///Lib/OptOutText/")?.editionGroupID == nil)
    }

    @Test func regroupForShelfLoadEnrichesTextOnlyRowFromOPFMetadata() async throws {
        let db = try DatabaseService(inMemory: ())
        let dao = AudiobookDAO(db: db.writer)
        let fm = FileManager.default

        // Two book folders, each holding an expanded fixture EPUB (dc:title
        // "Fixture Book", dc:creator "Tester") staged as `book.epub` the way an
        // import lays it out.
        func makeBookFolder(_ name: String) throws -> URL {
            let folder = fm.temporaryDirectory
                .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let fixture = try TestEPUBFixture.twoChapters(in: folder)
            try fm.moveItem(
                at: fixture, to: folder.appendingPathComponent("book.epub", isDirectory: true))
            return folder
        }
        let placeholderFolder = try makeBookFolder("enrich-placeholder")
        let customFolder = try makeBookFolder("enrich-custom")
        defer {
            try? fm.removeItem(at: placeholderFolder)
            try? fm.removeItem(at: customFolder)
        }

        // Row 1 carries the folder-name placeholder persistAudiobook writes.
        let placeholderID = placeholderFolder.absoluteString
        try dao.save(
            AudiobookRecord(
                id: placeholderID,
                title: placeholderFolder.deletingPathExtension().lastPathComponent,
                author: nil, duration: 0, fileCount: 0,
                addedAt: "2026-07-10T00:00:00Z", isAvailable: true))
        // Row 2 already has a meaningful title that must survive enrichment.
        let customID = customFolder.absoluteString
        try dao.save(
            AudiobookRecord(
                id: customID, title: "My Curated Title", author: nil,
                duration: 0, fileCount: 0, addedAt: "2026-07-10T00:00:01Z", isAvailable: true))

        let now = try Date("2026-07-10T00:30:00Z", strategy: .iso8601)
        let service = LibraryService(db: db)
        let changed = await service.regroupForShelfLoad(now: { now })

        #expect(changed)
        let placeholder = try #require(try dao.get(placeholderID))
        #expect(placeholder.author == "Tester")
        #expect(placeholder.title == "Fixture Book")
        let custom = try #require(try dao.get(customID))
        #expect(custom.author == "Tester")
        #expect(custom.title == "My Curated Title")
    }

    @Test func regroupForShelfLoadPrunesAbandonedContainerRows() async throws {
        let db = try DatabaseService(inMemory: ())
        let dao = AudiobookDAO(db: db.writer)
        let now = try Date("2026-07-11T00:00:00Z", strategy: .iso8601)

        // Abandoned container pick: no audio, no text, purely local, a day old.
        try dao.save(
            AudiobookRecord(
                id: "file:///Lib/AudioBookBay/", title: "AudioBookBay", author: nil,
                duration: 0, fileCount: 0, addedAt: "2026-07-10T00:00:00Z", isAvailable: true))
        // Same shape, 30 minutes old: an import may still be writing content.
        try dao.save(
            AudiobookRecord(
                id: "file:///Lib/FreshPick/", title: "FreshPick", author: nil,
                duration: 0, fileCount: 0, addedAt: "2026-07-10T23:30:00Z", isAvailable: true))
        // Same shape but with saved progress: pruning would cascade it away.
        try dao.save(
            AudiobookRecord(
                id: "file:///Lib/HasProgress/", title: "HasProgress", author: nil,
                duration: 0, fileCount: 0, addedAt: "2026-07-10T00:00:00Z", isAvailable: true))
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO playback_state (audiobook_id, last_position, speed)
                    VALUES (?, 42, 1.0)
                    """,
                arguments: ["file:///Lib/HasProgress/"])
        }
        // Server-sourced rows are never local junk, whatever their columns say.
        try dao.save(
            AudiobookRecord(
                id: "abs-empty", title: "ABS Placeholder", author: nil,
                duration: 0, fileCount: 0, addedAt: "2026-07-10T00:00:00Z",
                sourceType: "audiobookshelf", isAvailable: true))

        let service = LibraryService(db: db)
        let changed = await service.regroupForShelfLoad(now: { now })

        #expect(changed)
        #expect(try dao.get("file:///Lib/AudioBookBay/") == nil)
        #expect(try dao.get("file:///Lib/FreshPick/") != nil)
        #expect(try dao.get("file:///Lib/HasProgress/") != nil)
        #expect(try dao.get("abs-empty") != nil)
    }

    @Test func regroupForShelfLoadCollapsesDirectOpenDuplicateOntoScannedRow() async throws {
        // The screenshot duplicate: the scanner keyed the book by its
        // standardized folder URL while a direct open persisted the picker's
        // "/private"-prefixed form. After the regroup both must share a group,
        // with the scanner-managed (rooted) row fronting the card and the
        // cover borrowed from the direct-open twin. Foundation only strips
        // "/private" for paths that exist, so this needs a real directory.
        let fm = FileManager.default
        let base = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("lib-dup-\(UUID().uuidString)", isDirectory: true)
        let folder = base.appendingPathComponent("Book", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let scannedID = folder.standardizedFileURL.absoluteString
        let pickedID = "file:///private\(folder.path)/"

        let db = try DatabaseService(inMemory: ())
        let dao = AudiobookDAO(db: db.writer)
        try dao.save(
            AudiobookRecord(
                id: scannedID, title: "AI", author: "Roman", duration: 50,
                fileCount: 1, addedAt: "2026-07-10T00:00:00Z", isAvailable: true,
                sourceRootID: "root-1"))
        // Newer and longer than the rooted row — without the rooted preference
        // the collapse would front this raw duplicate instead.
        try dao.save(
            AudiobookRecord(
                id: pickedID, title: "Book", author: nil, duration: 100,
                fileCount: 1, addedAt: "2026-07-10T00:00:01Z", coverArtPath: "direct.jpg",
                isAvailable: true))

        let service = LibraryService(db: db)
        #expect(await service.regroupForShelfLoad())

        let books = try service.books(includeUnavailable: false)
        #expect(books.map(\.id) == [scannedID])
        #expect(books.first?.coverArtPath == "direct.jpg")
    }

    @Test func regroupForShelfLoadFillsCoverFromAudioArtworkExtractor() async throws {
        let db = try DatabaseService(inMemory: ())
        let dao = AudiobookDAO(db: db.writer)
        let audioID = "file:///Lib/CoverAudio-\(UUID().uuidString)/"
        let coveredID = "file:///Lib/AlreadyCovered-\(UUID().uuidString)/"
        try dao.save(
            AudiobookRecord(
                id: audioID, title: "Needs A Cover", author: "Someone", duration: 100,
                fileCount: 1, addedAt: "2026-07-10T00:00:00Z", isAvailable: true))
        try dao.save(
            AudiobookRecord(
                id: coveredID, title: "Already Covered", author: "Someone Else", duration: 100,
                fileCount: 1, addedAt: "2026-07-10T00:00:00Z", coverArtPath: "kept.jpg",
                isAvailable: true))

        let coversDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("covers-enrich-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: coversDir) }

        let service = LibraryService(db: db)
        let changed = await service.regroupForShelfLoad(
            coversDir: coversDir,
            coverData: { _ in Data([0xFF, 0xD8, 0xFF]) })

        #expect(changed)
        let enriched = try #require(try dao.get(audioID))
        let coverPath = try #require(enriched.coverArtPath)
        #expect(
            FileManager.default.fileExists(
                atPath: coversDir.appendingPathComponent(coverPath).path))
        #expect(try dao.get(coveredID)?.coverArtPath == "kept.jpg")

        // A book with no extractable artwork is remembered for the session and
        // not re-attempted on the next shelf load.
        #expect(
            await service.regroupForShelfLoad(
                coversDir: coversDir, coverData: { _ in nil }) == false)
    }

    // MARK: - Task 10: derived study + processing status

    @Test func processingStatusReflectsNarrationAndTranscription() throws {
        let db = try DatabaseService(inMemory: ())
        try db.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO audiobook (id, title, duration) VALUES ('bk', 'T', 100)
                    """)
            try db.execute(
                sql: """
                    INSERT INTO track (id, audiobook_id, title, duration, file_path, sort_order, narration_voice)
                    VALUES ('t1', 'bk', 'c1', 50, '/bk/c1.wav', 0, 'af_heart')
                    """)
        }
        let service = LibraryService(db: db)
        let book = try #require(try AudiobookDAO(db: db.writer).get("bk"))
        #expect(try service.processingStatus(for: book).contains(.narrated))
        #expect(!(try service.processingStatus(for: book).contains(.transcribed)))
    }

    @Test func studyStatusNotStartedWithNoPlayback() throws {
        let db = try DatabaseService(inMemory: ())
        try db.writer.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration) VALUES ('bk','T',100)")
        }
        let service = LibraryService(db: db)
        let book = try #require(try AudiobookDAO(db: db.writer).get("bk"))
        #expect(try service.studyStatus(for: book) == .notStarted)

        // Zero-position is also .notStarted (guards the `pos > 0` check from
        // being loosened to a mere nil-check later).
        try db.writer.write { db in
            try db.execute(
                sql: "INSERT INTO playback_state (audiobook_id, last_position) VALUES ('bk', 0)")
        }
        #expect(try service.studyStatus(for: book) == .notStarted)
    }

    @Test func processingStatusReflectsTranscription() throws {
        let db = try DatabaseService(inMemory: ())
        try db.writer.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('bk', 'T', 100)")
            try db.execute(
                sql: """
                    INSERT INTO transcription_segment (audiobook_id, start_time, end_time, text)
                    VALUES ('bk', 0.0, 1.0, 'Hello world')
                    """)
        }
        let service = LibraryService(db: db)
        let book = try #require(try AudiobookDAO(db: db.writer).get("bk"))
        #expect(try service.processingStatus(for: book).contains(.transcribed))
        #expect(!(try service.processingStatus(for: book).contains(.narrated)))
    }

    @Test func processingStatusAlignedRequiresMoreThanSeedAnchors() throws {
        let db = try DatabaseService(inMemory: ())
        let audiobookID = "bk-align"
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, 'T', 100)",
                arguments: [audiobookID])
        }
        try EPubBlockDAO(db: db.writer).insertAll([
            EPubBlockRecord(
                id: "eb0", audiobookID: audiobookID, spineHref: "ch1.xhtml",
                spineIndex: 0, blockIndex: 0, sequenceIndex: 0,
                blockKind: "paragraph", text: "Some text",
                chapterIndex: 0, isHidden: false)
        ])
        let dao = AlignmentAnchorDAO(db: db.writer)
        let iso = AlignmentService.isoFormatter
        func makeAnchor(id: String, time: Double) -> AlignmentAnchorRecord {
            AlignmentAnchorRecord(
                id: id, audiobookID: audiobookID, epubBlockID: "eb0",
                audioTime: time, audioEndTime: nil,
                anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
                source: AlignmentAnchorRecord.Source.imported.rawValue, note: nil,
                createdAt: iso.string(from: Date()), modifiedAt: nil)
        }
        try dao.insert(makeAnchor(id: "anc-1", time: 0))
        try dao.insert(makeAnchor(id: "anc-2", time: 10))

        let service = LibraryService(db: db)
        let book = try #require(try AudiobookDAO(db: db.writer).get(audiobookID))

        // Two anchors = seed only; .aligned should NOT be present
        #expect(!(try service.processingStatus(for: book).contains(.aligned)))

        // Insert a third anchor — now aligned
        try dao.insert(makeAnchor(id: "anc-3", time: 20))
        #expect(try service.processingStatus(for: book).contains(.aligned))
    }

    @Test func studyStatusInProgressAndFinished() throws {
        let db = try DatabaseService(inMemory: ())
        try db.writer.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('bk', 'T', 100)")
            try db.execute(
                sql: "INSERT INTO playback_state (audiobook_id, last_position) VALUES ('bk', 50)")
        }
        let service = LibraryService(db: db)
        let book = try #require(try AudiobookDAO(db: db.writer).get("bk"))

        #expect(try service.studyStatus(for: book) == .inProgress)

        try db.writer.write { db in
            try db.execute(
                sql: "UPDATE playback_state SET last_position = 99 WHERE audiobook_id = 'bk'")
        }
        #expect(try service.studyStatus(for: book) == .finished)
    }

    @Test func statusSectionsFoldSiblingEditionStatuses() throws {
        // Playback and narration recorded against a hidden duplicate row must
        // move the visible card into the matching status sections — not leave
        // it under Not Started / Not Processed while its badge says otherwise.
        let db = try DatabaseService(inMemory: ())
        let dao = AudiobookDAO(db: db.writer)
        try dao.save(
            AudiobookRecord(
                id: "file:///Lib/SectVisible/", title: "Sectioned", author: "An Author",
                duration: 100, fileCount: 1, addedAt: "2026-07-10T00:00:00Z",
                isAvailable: true, sourceRootID: "root-1", editionGroupID: "sect-g"))
        try dao.save(
            AudiobookRecord(
                id: "file:///Lib/SectDirect/", title: "Sectioned", author: "An Author",
                duration: 100, fileCount: 1, addedAt: "2026-07-10T00:00:01Z",
                isAvailable: true, editionGroupID: "sect-g"))
        try db.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO playback_state (audiobook_id, last_position, speed)
                    VALUES ('file:///Lib/SectDirect/', 99, 1.0)
                    """)
            try db.execute(
                sql: """
                    INSERT INTO track
                        (id, audiobook_id, title, duration, file_path, sort_order,
                         narration_voice)
                    VALUES ('t-sect', 'file:///Lib/SectDirect/', 'T', 10, 'file:///t.mp3', 0,
                            'af_heart')
                    """)
        }
        let service = LibraryService(db: db)

        let study = try service.sections(by: .studyStatus, includeUnavailable: false)
        #expect(study.map(\.title) == ["Finished"])
        #expect(study.first?.books.map(\.id) == ["file:///Lib/SectVisible/"])

        let processing = try service.sections(by: .processingStatus, includeUnavailable: false)
        #expect(processing.map(\.title) == ["Narrated"])
        #expect(processing.first?.books.map(\.id) == ["file:///Lib/SectVisible/"])
    }

    @Test func urlForOpeningResolvesViaRoot() throws {
        let db = try DatabaseService(inMemory: ())
        let service = LibraryService(db: db)

        // Create a REAL temp directory so the bookmark resolves.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lib-open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let root = try service.registerRoot(url: tmp, now: fixedNow)

        // A child folder under the temp root.
        let childURL = tmp.appendingPathComponent("MyBook", isDirectory: true)
        try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: true)

        let book = AudiobookRecord(
            id: childURL.absoluteString,
            title: "MyBook",
            author: nil,
            duration: 0,
            fileCount: nil,
            addedAt: "2026-06-27T00:00:00Z",
            isAvailable: true,
            sourceRootID: root.id)
        try AudiobookDAO(db: db.writer).save(book)

        let target = try service.urlForOpening(book)
        #expect(target.url.standardizedFileURL == childURL.standardizedFileURL)
        // The root scope is handed back to the caller (NOT entered here).
        #expect(target.scopedRoot != nil)
        #expect(target.scopedRoot?.standardizedFileURL == tmp.standardizedFileURL)

        // Fallback: book with no sourceRootID and a valid file:// id returns that
        // URL with a nil scopedRoot (no security scope to manage).
        let standaloneBook = AudiobookRecord(
            id: childURL.absoluteString,
            title: "StandaloneBook",
            author: nil,
            duration: 0,
            fileCount: nil,
            addedAt: "2026-06-27T00:00:00Z",
            isAvailable: true,
            sourceRootID: nil)
        let fallback = try service.urlForOpening(standaloneBook)
        #expect(fallback.url.standardizedFileURL == childURL.standardizedFileURL)
        #expect(fallback.scopedRoot == nil)
    }
}
