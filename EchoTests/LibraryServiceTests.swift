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
