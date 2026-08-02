// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import GRDB
import Testing

@testable import Echo

@Suite("Generated anthology import")
struct GeneratedAnthologyImportTests {
    @Test("Trusted generated metadata creates stable IDs while cover stays non-generated")
    func trustedParseUsesManifestIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manifest = fixture.manifest(chapters: [
            fixture.chapter(slot: 0, order: 0, title: "Article A", body: "Alpha")
        ])
        let expanded = try fixture.writeExpandedEPUB(manifest)
        let audiobookID = "generated-book"

        let parsed = try parseEPUBBlocks(
            audiobookID: audiobookID,
            epubURL: expanded,
            generatedIdentity: try GeneratedAnthologyImportIdentity(manifest: manifest))

        let generated = parsed.blocks.filter { $0.sourceChapterKey != nil }
        #expect(
            generated.map(\.id) == [
                "epub-generated-book-s0-b0",
                "epub-generated-book-s0-b2",
                "epub-generated-book-s0-b1004",
                "epub-generated-book-s0-b900000",
            ])
        #expect(Set(generated.map(\.sourceChapterKey)) == [manifest.chapters[0].entryID.uuidString])
        let cover = try #require(parsed.blocks.first { $0.spineHref == "cover.xhtml" })
        #expect(cover.sourceChapterKey == nil)
        #expect(cover.id != "epub-generated-book-s0-b0")
    }

    @Test("Legacy edge whitespace uses the parser's canonical block identity")
    func legacyEdgeWhitespaceUsesCanonicalIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manifest = fixture.manifest(chapters: [
            fixture.chapter(slot: 0, order: 0, title: "Article", body: "Body with legacy space ")
        ])

        let parsed = try parseEPUBBlocks(
            audiobookID: "legacy-whitespace",
            epubURL: fixture.writeExpandedEPUB(manifest),
            generatedIdentity: try GeneratedAnthologyImportIdentity(manifest: manifest))

        #expect(parsed.blocks.contains {
            $0.id == "epub-legacy-whitespace-s0-b1004" && $0.text == "Body with legacy space"
        })
    }

    @Test("Long generated titles keep their validated stable block set")
    func longGeneratedTitleDoesNotSynthesizeAHeading() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let title = String(repeating: "Long generated anthology title ", count: 5)
            .trimmingCharacters(in: .whitespaces)
        #expect(title.count > 100)
        let manifest = fixture.manifest(chapters: [
            fixture.chapter(slot: 0, order: 0, title: title, body: "Body")
        ])

        let parsed = try parseEPUBBlocks(
            audiobookID: "long-title",
            epubURL: fixture.writeExpandedEPUB(manifest),
            generatedIdentity: try GeneratedAnthologyImportIdentity(manifest: manifest))

        let generated = parsed.blocks.filter { $0.sourceChapterKey != nil }
        #expect(generated.count == 4)
        #expect(generated.map(\.id) == [
            "epub-long-title-s0-b0",
            "epub-long-title-s0-b2",
            "epub-long-title-s0-b1004",
            "epub-long-title-s0-b900000",
        ])
        #expect(generated.first?.text == title)
    }

    @Test("Generated block kinds bypass generic EPUB heading heuristics")
    func generatedKindsBypassHeuristics() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let chapter = fixture.withAuthor(
            "AUTHOR",
            in: fixture.chapter(slot: 0, order: 0, title: "Article", body: "Body"))
        let manifest = fixture.manifest(chapters: [chapter])

        let parsed = try parseEPUBBlocks(
            audiobookID: "trusted-kinds",
            epubURL: fixture.writeExpandedEPUB(manifest),
            generatedIdentity: try GeneratedAnthologyImportIdentity(manifest: manifest))

        let byline = try #require(parsed.blocks.first { $0.id == "epub-trusted-kinds-s0-b1" })
        #expect(byline.blockKind == EPubBlockRecord.Kind.paragraph.rawValue)
        #expect(byline.text == "AUTHOR")
    }

    @Test("Reordering chapters changes location fields but not stable IDs")
    func reorderKeepsStableIDs() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let a = fixture.chapter(slot: 8, order: 0, title: "Article A", body: "Alpha")
        let b = fixture.chapter(slot: 21, order: 1, title: "Article B", body: "Bravo")
        let firstManifest = fixture.manifest(chapters: [a, b])
        let reorderedManifest = fixture.manifest(
            revision: 2,
            chapters: [
                fixture.reordered(b, order: 0),
                fixture.reordered(a, order: 1),
            ])

        let first = try parseEPUBBlocks(
            audiobookID: "book",
            epubURL: fixture.writeExpandedEPUB(firstManifest, name: "first"),
            generatedIdentity: try GeneratedAnthologyImportIdentity(manifest: firstManifest))
        let second = try parseEPUBBlocks(
            audiobookID: "book",
            epubURL: fixture.writeExpandedEPUB(reorderedManifest, name: "second"),
            generatedIdentity: try GeneratedAnthologyImportIdentity(manifest: reorderedManifest))

        let firstByID = Dictionary(
            uniqueKeysWithValues: first.blocks.compactMap {
                $0.sourceChapterKey == nil ? nil : ($0.id, $0)
            })
        let secondByID = Dictionary(
            uniqueKeysWithValues: second.blocks.compactMap {
                $0.sourceChapterKey == nil ? nil : ($0.id, $0)
            })
        #expect(Set(firstByID.keys) == Set(secondByID.keys))
        let aID = "epub-book-s8-b1004"
        #expect(firstByID[aID]?.spineIndex == 1)
        #expect(secondByID[aID]?.spineIndex == 2)
        #expect(
            (firstByID[aID]?.sequenceIndex ?? -1)
                < (firstByID["epub-book-s21-b1004"]?.sequenceIndex ?? -1))
        #expect(
            (secondByID[aID]?.sequenceIndex ?? -1)
                > (secondByID["epub-book-s21-b1004"]?.sequenceIndex ?? -1))
    }

    @Test("External EPUB attributes cannot opt into stable generated IDs")
    func genericParserIgnoresForgedMetadata() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manifest = fixture.manifest(chapters: [
            fixture.chapter(slot: 91, order: 0, title: "Forged", body: "Payload")
        ])
        let expanded = try fixture.writeExpandedEPUB(manifest)

        let parsed = try parseEPUBBlocks(audiobookID: "external", epubURL: expanded)
        let forgedStableID = "epub-external-s91-b1004"
        #expect(parsed.blocks.allSatisfy { $0.sourceChapterKey == nil })
        #expect(parsed.blocks.contains { $0.id == forgedStableID } == false)
        #expect(parsed.blocks.contains { $0.id == "epub-external-s1-b3" })
    }

    @Test(
        "Wrong trusted package evidence fails before any stable ID is returned",
        arguments: [EvidenceMutation.identifier, .manifestDigest]
    )
    func packageEvidenceFailsClosed(mutation: EvidenceMutation) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manifest = fixture.manifest(chapters: [
            fixture.chapter(slot: 3, order: 0, title: "Article", body: "Body")
        ])
        let expanded = try fixture.writeExpandedEPUB(manifest, mutation: mutation)

        #expect(throws: GeneratedAnthologyImportError.self) {
            _ = try parseEPUBBlocks(
                audiobookID: "book",
                epubURL: expanded,
                generatedIdentity: try GeneratedAnthologyImportIdentity(manifest: manifest))
        }
    }

    @Test(
        "Malformed trusted chapter metadata fails closed",
        arguments: [
            ContentMutation.href,
            .stableSlot,
            .blockIndex,
            .kind,
            .text,
            .duplicateBlock,
            .missingBlock,
        ]
    )
    func malformedTrustedChapterFailsClosed(mutation: ContentMutation) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manifest = fixture.manifest(chapters: [
            fixture.chapter(slot: 13, order: 0, title: "Article", body: "Body")
        ])
        let expanded = try fixture.writeExpandedEPUB(
            manifest,
            contentMutation: mutation)

        #expect(throws: GeneratedAnthologyImportError.self) {
            _ = try parseEPUBBlocks(
                audiobookID: "book",
                epubURL: expanded,
                generatedIdentity: try GeneratedAnthologyImportIdentity(manifest: manifest))
        }
    }

    @Test("Reconcile preserves user state and clears derived rows only for changed blocks")
    @MainActor
    func reconcilePreservesAndInvalidatesPrecisely() async throws {
        let service = try DatabaseService(inMemory: ())
        let audiobookID = "book-reconcile"
        try Self.seedAudiobook(audiobookID, in: service.writer)
        let unchangedID = "epub-\(audiobookID)-s8-b1004"
        let changedID = "epub-\(audiobookID)-s21-b1004"
        let removedID = "epub-\(audiobookID)-s21-b1005"
        let otherBookID = "other-book"
        try Self.seedAudiobook(otherBookID, in: service.writer)
        try await service.writer.write { database in
            for block in [
                Self.block(unchangedID, audiobookID, "entry-a", "Alpha", sequence: 0),
                Self.block(changedID, audiobookID, "entry-b", "Bravo old", sequence: 1),
                Self.block(removedID, audiobookID, "entry-b", "Removed", sequence: 2),
                Self.block(
                    "epub-other-book-s21-b1005", otherBookID, "entry-z", "Other", sequence: 0),
            ] {
                var value = block
                try value.insert(database)
            }
            try Self.seedUserAndDerivedRows(
                database,
                audiobookID: audiobookID,
                unchangedID: unchangedID,
                changedID: changedID,
                removedID: removedID)
        }

        let incoming = [
            Self.block(changedID, audiobookID, "entry-b", "Bravo changed", sequence: 0, spine: 1),
            Self.block(unchangedID, audiobookID, "entry-a", "Alpha", sequence: 1, spine: 2),
            Self.block(
                "epub-\(audiobookID)-s8-b1006", audiobookID, "entry-a", "New", sequence: 2, spine: 2
            ),
        ]
        try await service.writer.write { database in
            try GeneratedAnthologyImportReconciler.reconcile(
                audiobookID: audiobookID,
                incomingBlocks: incoming,
                tocEntries: [],
                in: database)
        }

        try await service.writer.read { database in
            guard let unchanged = try EPubBlockRecord.fetchOne(database, key: unchangedID) else {
                Issue.record("Expected unchanged block")
                return
            }
            #expect(unchanged.sequenceIndex == 1)
            #expect(unchanged.spineIndex == 2)
            #expect(unchanged.cardColor == "#112233")
            #expect(unchanged.isHidden)
            let unchangedDerived = try Self.derivedCount(database, blockID: unchangedID)
            #expect(unchangedDerived == 3)

            guard let changed = try EPubBlockRecord.fetchOne(database, key: changedID) else {
                Issue.record("Expected changed block")
                return
            }
            #expect(changed.text == "Bravo changed")
            #expect(changed.cardColor == "#112233")
            #expect(changed.isHidden)
            let changedDerived = try Self.derivedCount(database, blockID: changedID)
            #expect(changedDerived == 0)

            let removed = try EPubBlockRecord.fetchOne(database, key: removedID)
            let removedDerived = try Self.derivedCount(database, blockID: removedID)
            let note = try NoteRecord.fetchOne(database, key: "note-removed")
            let bookmark = try BookmarkRecord.fetchOne(
                database, key: "bookmark-generated")
            let other = try EPubBlockRecord.fetchOne(
                database, key: "epub-other-book-s21-b1005")
            #expect(removed == nil)
            #expect(removedDerived == 0)
            #expect(note != nil)
            #expect(bookmark != nil)
            #expect(other != nil)
        }
    }

    @Test("Injected reconcile failure rolls back every mutation")
    @MainActor
    func reconcileRollbackIsAtomic() async throws {
        let service = try DatabaseService(inMemory: ())
        let audiobookID = "book-rollback"
        try Self.seedAudiobook(audiobookID, in: service.writer)
        let original = Self.block(
            "epub-\(audiobookID)-s1-b1000", audiobookID, "entry", "Original", sequence: 0)
        try await service.writer.write { database in
            var value = original
            try value.insert(database)
        }

        let changed = Self.block(
            original.id, audiobookID, "entry", "Changed", sequence: 2)
        await #expect(throws: GeneratedAnthologyImportError.self) {
            try await service.writer.write { database in
                try GeneratedAnthologyImportReconciler.reconcile(
                    audiobookID: audiobookID,
                    incomingBlocks: [changed],
                    tocEntries: [],
                    faultInjector: { point in
                        if point == .afterUpserts {
                            throw GeneratedAnthologyImportError.injectedFailure
                        }
                    },
                    in: database)
            }
        }
        try await service.writer.read { database in
            let restored = try EPubBlockRecord.fetchOne(database, key: original.id)
            #expect(restored == original)
        }
    }

    @Test("Cross-book stable ID collision fails before mutation")
    @MainActor
    func crossBookCollisionFailsBeforeMutation() async throws {
        let service = try DatabaseService(inMemory: ())
        let requestedAudiobookID = "requested-book"
        let owningAudiobookID = "owning-book"
        try Self.seedAudiobook(requestedAudiobookID, in: service.writer)
        try Self.seedAudiobook(owningAudiobookID, in: service.writer)
        let collidingID = "epub-\(requestedAudiobookID)-s4-b1004"
        let owned = Self.block(
            collidingID,
            owningAudiobookID,
            "owner-entry",
            "Owned",
            sequence: 0)
        try await service.writer.write { database in
            var value = owned
            try value.insert(database)
        }
        let incoming = Self.block(
            collidingID,
            requestedAudiobookID,
            "requested-entry",
            "Incoming",
            sequence: 0)

        await #expect(throws: GeneratedAnthologyImportError.self) {
            try await service.writer.write { database in
                try GeneratedAnthologyImportReconciler.reconcile(
                    audiobookID: requestedAudiobookID,
                    incomingBlocks: [incoming],
                    tocEntries: [],
                    in: database)
            }
        }

        try await service.writer.read { database in
            let persisted = try EPubBlockRecord.fetchOne(database, key: collidingID)
            let requestedCount =
                try EPubBlockRecord
                .filter(Column("audiobook_id") == requestedAudiobookID)
                .fetchCount(database)
            #expect(persisted == owned)
            #expect(requestedCount == 0)
        }
    }

    @Test("Rollback snapshot restores one book exactly without touching another")
    @MainActor
    func rollbackSnapshotIsBoundedAndExact() async throws {
        let service = try DatabaseService(inMemory: ())
        let requestedAudiobookID = "snapshot-book"
        let otherAudiobookID = "snapshot-other"
        try Self.seedAudiobook(requestedAudiobookID, in: service.writer)
        try Self.seedAudiobook(otherAudiobookID, in: service.writer)
        let requested = Self.block(
            "epub-\(requestedAudiobookID)-s4-b1004",
            requestedAudiobookID,
            "requested-entry",
            "Prior text",
            sequence: 0)
        let other = Self.block(
            "epub-\(otherAudiobookID)-s9-b1004",
            otherAudiobookID,
            "other-entry",
            "Other prior",
            sequence: 0)
        try await service.writer.write { database in
            for block in [requested, other] {
                var value = block
                try value.insert(database)
                try Self.seedDerivedRows(database, block: value)
            }
        }
        let snapshot = try await service.writer.read { database in
            try GeneratedAnthologyImportRollbackSnapshot.capture(
                audiobookID: requestedAudiobookID,
                in: database)
        }

        try await service.writer.write { database in
            let changed = Self.block(
                requested.id,
                requestedAudiobookID,
                "requested-entry",
                "Candidate text",
                sequence: 0)
            let candidateOnly = Self.block(
                "epub-\(requestedAudiobookID)-s4-b1005",
                requestedAudiobookID,
                "requested-entry",
                "Candidate only",
                sequence: 1)
            try GeneratedAnthologyImportReconciler.reconcile(
                audiobookID: requestedAudiobookID,
                incomingBlocks: [changed, candidateOnly],
                tocEntries: [],
                in: database)
            var changedOther = other
            changedOther.text = "Other changed after capture"
            try changedOther.update(database)
        }

        try await service.writer.write { database in
            try snapshot.restore(
                audiobookID: requestedAudiobookID,
                in: database)
        }

        try await service.writer.read { database in
            let restored = try EPubBlockRecord.fetchOne(database, key: requested.id)
            let candidateOnly = try EPubBlockRecord.fetchOne(
                database,
                key: "epub-\(requestedAudiobookID)-s4-b1005")
            let unchangedOther = try EPubBlockRecord.fetchOne(database, key: other.id)
            #expect(restored == requested)
            #expect(try Self.derivedCount(database, blockID: requested.id) == 3)
            #expect(candidateOnly == nil)
            #expect(unchangedOther?.text == "Other changed after capture")
            #expect(try Self.derivedCount(database, blockID: other.id) == 3)
        }
    }

    @Test(
        "Rollback snapshot limits reject before candidate mutation",
        arguments: [SnapshotLimitMutation.count, .bytes]
    )
    @MainActor
    func rollbackSnapshotLimitsFailBeforeImport(
        mutation: SnapshotLimitMutation
    ) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = try DatabaseService(inMemory: ())
        let audiobookID = "snapshot-limit-book"
        try Self.seedAudiobook(audiobookID, in: service.writer)
        let manifest = fixture.manifest(chapters: [
            fixture.chapter(slot: 13, order: 0, title: "Article", body: "Candidate")
        ])
        let prior = Self.block(
            "epub-\(audiobookID)-s13-b1004",
            audiobookID,
            "prior-entry",
            "Prior",
            sequence: 0)
        try await service.writer.write { database in
            var value = prior
            try value.insert(database)
            try Self.seedDerivedRows(database, block: value)
        }
        let limits =
            switch mutation {
            case .count:
                GeneratedAnthologyImportRollbackSnapshot.Limits(maximumBlocks: 0)
            case .bytes:
                GeneratedAnthologyImportRollbackSnapshot.Limits(maximumEncodedBytes: 1)
            }

        do {
            _ = try await GeneratedAnthologyImportReconciler.importArchive(
                at: try fixture.writeArchive(manifest, name: "limit-\(mutation)"),
                audiobookID: audiobookID,
                identity: try GeneratedAnthologyImportIdentity(manifest: manifest),
                databaseService: service,
                rollbackLimits: limits)
            Issue.record("Expected snapshot limit rejection")
        } catch let error as GeneratedAnthologyImportError {
            #expect(error == .rollbackSnapshotLimitExceeded)
        }

        try await service.writer.read { database in
            let persisted = try EPubBlockRecord.fetchOne(database, key: prior.id)
            let derived = try Self.derivedCount(database, blockID: prior.id)
            let blockCount =
                try EPubBlockRecord
                .filter(Column("audiobook_id") == audiobookID)
                .fetchCount(database)
            #expect(persisted == prior)
            #expect(derived == 3)
            #expect(blockCount == 1)
        }
    }

    enum EvidenceMutation: Sendable {
        case identifier
        case manifestDigest
    }

    enum ContentMutation: Sendable {
        case href
        case stableSlot
        case blockIndex
        case kind
        case text
        case duplicateBlock
        case missingBlock
    }

    enum SnapshotLimitMutation: Sendable {
        case count
        case bytes
    }

    nonisolated private static func seedAudiobook(
        _ id: String,
        in writer: DatabaseWriter
    ) throws {
        try writer.write { database in
            var record = AudiobookRecord(
                id: id,
                title: id,
                author: nil,
                duration: 0,
                fileCount: 0,
                addedAt: "2026-07-28T00:00:00Z")
            try record.insert(database)
        }
    }

    nonisolated private static func block(
        _ id: String,
        _ audiobookID: String,
        _ sourceChapterKey: String,
        _ text: String,
        sequence: Int,
        spine: Int = 1
    ) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id,
            audiobookID: audiobookID,
            spineHref: "articles/\(sourceChapterKey).xhtml",
            spineIndex: spine,
            blockIndex: 1004,
            sequenceIndex: sequence,
            blockKind: EPubBlockRecord.Kind.paragraph.rawValue,
            text: text,
            htmlContent: "<p>\(text)</p>",
            cardColor: "#112233",
            chapterThemeColor: "#445566",
            imagePath: nil,
            chapterIndex: spine - 1,
            isHidden: true,
            hiddenReason: "reader",
            isFrontMatter: false,
            wordCount: 1,
            markers: nil,
            textFormats: nil,
            narrationText: nil,
            codeLanguage: nil,
            sourceChapterKey: sourceChapterKey,
            createdAt: "2026-07-28T00:00:00Z",
            modifiedAt: nil)
    }

    nonisolated private static func seedUserAndDerivedRows(
        _ database: Database,
        audiobookID: String,
        unchangedID: String,
        changedID: String,
        removedID: String
    ) throws {
        for blockID in [unchangedID, changedID, removedID] {
            guard let fetched = try EPubBlockRecord.fetchOne(database, key: blockID) else {
                throw GeneratedAnthologyImportError.invalidStableBlock
            }
            try seedDerivedRows(database, block: fetched)
        }
        var note = NoteRecord(
            id: "note-removed",
            audiobookID: audiobookID,
            text: "Keep me",
            mediaTimestamp: 1,
            realTimestamp: nil,
            isEnabled: true,
            playlistPosition: nil,
            createdAt: "2026-07-28T00:00:00Z",
            modifiedAt: "2026-07-28T00:00:00Z",
            epubBlockID: removedID)
        try note.insert(database)
        var bookmark = BookmarkRecord(
            id: "bookmark-generated",
            audiobookID: audiobookID,
            trackID: nil,
            title: "Keep this bookmark",
            mediaTimestamp: 1,
            note: nil,
            voiceMemoPath: nil,
            imagePath: nil,
            isEnabled: true,
            playlistPosition: nil,
            pdfViewStateJSON: nil,
            latitude: nil,
            longitude: nil,
            placeName: nil,
            createdAt: "2026-07-28T00:00:00Z",
            modifiedAt: "2026-07-28T00:00:00Z")
        try bookmark.insert(database)
    }

    nonisolated private static func seedDerivedRows(
        _ database: Database,
        block: EPubBlockRecord
    ) throws {
        var anchor = AlignmentAnchorRecord(
            id: "anchor-\(block.id)",
            audiobookID: block.audiobookID,
            epubBlockID: block.id,
            audioTime: 1,
            audioEndTime: 2,
            anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
            source: AlignmentAnchorRecord.Source.synthesized.rawValue,
            note: nil,
            createdAt: nil,
            modifiedAt: nil)
        try anchor.insert(database)
        var timing = WordTimingRecord(
            audiobookID: block.audiobookID,
            epubBlockID: block.id,
            wordIndex: 0,
            word: "word",
            audioStartTime: 1,
            audioEndTime: 2,
            confidence: 1,
            source: "synthesis")
        try timing.insert(database)
        var timeline = TimelineItem.fromEPubBlock(
            block,
            audiobookID: block.audiobookID)
        timeline.audioStartTime = 1
        try timeline.insert(database)
    }

    nonisolated private static func derivedCount(
        _ database: Database,
        blockID: String
    ) throws -> Int {
        let anchors =
            try AlignmentAnchorRecord
            .filter(Column("epub_block_id") == blockID).fetchCount(database)
        let timings =
            try WordTimingRecord
            .filter(Column("epub_block_id") == blockID).fetchCount(database)
        let timeline =
            try TimelineItem
            .filter(Column("source_table") == "epub_block")
            .filter(Column("epub_block_id") == blockID)
            .fetchCount(database)
        return anchors + timings + timeline
    }

    private final class Fixture {
        let root: URL
        private let anthologyID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appending(
                    path: "echo-generated-import-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        func manifest(
            revision: Int = 1,
            chapters: [AnthologyChapterManifest]
        ) -> AnthologyBuildManifest {
            AnthologyBuildManifest(
                schemaVersion: 1,
                anthologyID: anthologyID,
                revision: revision,
                epubIdentifier: "urn:uuid:\(anthologyID.uuidString)",
                title: "Anthology",
                subtitle: nil,
                creator: "Echo",
                language: "en",
                coverPath: nil,
                modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                chapters: chapters)
        }

        func chapter(
            slot: Int,
            order: Int,
            title: String,
            body: String
        ) -> AnthologyChapterManifest {
            let entryID = Self.uuid(seed: slot + 1)
            let block = ArticleBlock(
                id: "block-\(slot)",
                stableOrdinal: 4,
                kind: .paragraph,
                text: body,
                sourceURL: nil,
                imageCandidateURL: nil,
                caption: nil,
                codeLanguage: nil)
            return AnthologyChapterManifest(
                entryID: entryID,
                captureID: Self.uuid(seed: slot + 100),
                articleRevisionID: Self.uuid(seed: slot + 200),
                stableSlot: slot,
                order: order,
                title: title,
                author: nil,
                siteName: "Example",
                sourceURL: URL(string: "https://example.test/\(slot)")!,
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                voiceID: nil,
                blocks: [block],
                readableContentSHA256: ArticleWorkshopDigest.readableContent(blocks: [block]))
        }

        func reordered(
            _ chapter: AnthologyChapterManifest,
            order: Int
        ) -> AnthologyChapterManifest {
            AnthologyChapterManifest(
                entryID: chapter.entryID,
                captureID: chapter.captureID,
                articleRevisionID: chapter.articleRevisionID,
                stableSlot: chapter.stableSlot,
                order: order,
                title: chapter.title,
                author: chapter.author,
                siteName: chapter.siteName,
                sourceURL: chapter.sourceURL,
                capturedAt: chapter.capturedAt,
                voiceID: chapter.voiceID,
                blocks: chapter.blocks,
                readableContentSHA256: chapter.readableContentSHA256)
        }

        func withAuthor(
            _ author: String,
            in chapter: AnthologyChapterManifest
        ) -> AnthologyChapterManifest {
            AnthologyChapterManifest(
                entryID: chapter.entryID,
                captureID: chapter.captureID,
                articleRevisionID: chapter.articleRevisionID,
                stableSlot: chapter.stableSlot,
                order: chapter.order,
                title: chapter.title,
                author: author,
                siteName: chapter.siteName,
                sourceURL: chapter.sourceURL,
                capturedAt: chapter.capturedAt,
                voiceID: chapter.voiceID,
                blocks: chapter.blocks,
                readableContentSHA256: chapter.readableContentSHA256)
        }

        func writeExpandedEPUB(
            _ manifest: AnthologyBuildManifest,
            name: String = "book",
            mutation: EvidenceMutation? = nil,
            contentMutation: ContentMutation? = nil
        ) throws -> URL {
            let directory = root.appending(path: name, directoryHint: .isDirectory)
            let meta = directory.appending(path: "META-INF", directoryHint: .isDirectory)
            let epub = directory.appending(path: "EPUB", directoryHint: .isDirectory)
            let articles = epub.appending(path: "articles", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: articles, withIntermediateDirectories: true)
            try Data(EPUBXMLWriter.container.utf8).write(
                to: meta.appending(path: "container.xml"))

            var packageManifest = manifest
            if mutation == .identifier {
                packageManifest = AnthologyBuildManifest(
                    schemaVersion: manifest.schemaVersion,
                    anthologyID: manifest.anthologyID,
                    revision: manifest.revision,
                    epubIdentifier: "urn:uuid:FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF",
                    title: manifest.title,
                    subtitle: manifest.subtitle,
                    creator: manifest.creator,
                    language: manifest.language,
                    coverPath: manifest.coverPath,
                    modifiedAt: manifest.modifiedAt,
                    chapters: manifest.chapters)
            }
            let digest =
                mutation == .manifestDigest
                ? String(repeating: "0", count: 64)
                : try Self.manifestSHA256(manifest)
            let cover = EPUBXMLWriter.CoverAsset(
                filename: "cover.svg",
                mediaType: "image/svg+xml",
                data: Data())
            var package = EPUBXMLWriter.package(
                manifest: packageManifest,
                manifestSHA256: digest,
                chapters: manifest.chapters.sorted { $0.order < $1.order },
                cover: cover)
            if contentMutation == .href, let chapter = manifest.chapters.first {
                package = package.replacingOccurrences(
                    of: "articles/article-s\(chapter.stableSlot).xhtml",
                    with: "articles/forged.xhtml")
            }
            try Data(package.utf8).write(to: epub.appending(path: "package.opf"))
            try Data(
                """
                <?xml version="1.0" encoding="UTF-8"?>
                <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Cover</title></head>
                <body><img src="images/cover.svg" alt="Cover"/></body></html>
                """.utf8
            ).write(to: epub.appending(path: "cover.xhtml"))
            for chapter in manifest.chapters {
                var xhtml = EPUBXMLWriter.chapter(chapter, language: manifest.language)
                if chapter.entryID == manifest.chapters.first?.entryID {
                    xhtml = Self.mutate(
                        xhtml,
                        chapter: chapter,
                        mutation: contentMutation)
                }
                try Data(xhtml.utf8)
                    .write(
                        to: articles.appending(
                            path: "article-s\(chapter.stableSlot).xhtml"))
            }
            return directory
        }

        func writeArchive(
            _ manifest: AnthologyBuildManifest,
            name: String
        ) throws -> URL {
            let destination = root.appending(path: "\(name).epub")
            _ = try AnthologyEPUBBuilder(workshopRoot: root)
                .build(manifest: manifest, to: destination)
            return destination
        }

        private static func mutate(
            _ xhtml: String,
            chapter: AnthologyChapterManifest,
            mutation: ContentMutation?
        ) -> String {
            guard let mutation else { return xhtml }
            let slot = chapter.stableSlot
            guard let block = chapter.blocks.first else { return xhtml }
            let index = 1_000 + block.stableOrdinal
            let body =
                "<p id=\"echo-s\(slot)-b\(index)\" "
                + "data-echo-stable-slot=\"\(slot)\" "
                + "data-echo-block-index=\"\(index)\">"
                + "\(EPUBXMLWriter.escapeText(block.text ?? ""))</p>"

            switch mutation {
            case .href:
                return xhtml
            case .stableSlot:
                return xhtml.replacingOccurrences(
                    of: "data-echo-stable-slot=\"\(slot)\"",
                    with: "data-echo-stable-slot=\"\(slot + 1)\"")
            case .blockIndex:
                return xhtml.replacingOccurrences(
                    of: "data-echo-block-index=\"\(index)\"",
                    with: "data-echo-block-index=\"\(index + 1)\"")
            case .kind:
                return xhtml.replacingOccurrences(
                    of: body,
                    with:
                        body
                        .replacingOccurrences(of: "<p ", with: "<h2 ")
                        .replacingOccurrences(of: "</p>", with: "</h2>"))
            case .text:
                return xhtml.replacingOccurrences(
                    of: body,
                    with: body.replacingOccurrences(
                        of: EPUBXMLWriter.escapeText(block.text ?? ""),
                        with: "Tampered"))
            case .duplicateBlock:
                return xhtml.replacingOccurrences(of: body, with: "\(body)\n    \(body)")
            case .missingBlock:
                return xhtml.replacingOccurrences(of: "    \(body)\n", with: "")
            }
        }

        private static func manifestSHA256(_ manifest: AnthologyBuildManifest) throws -> String {
            let encoder = JSONEncoder.articleWorkshop
            encoder.outputFormatting = [.sortedKeys]
            return SHA256.hash(data: try encoder.encode(manifest))
                .map { String(format: "%02x", $0) }.joined()
        }

        private static func uuid(seed: Int) -> UUID {
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", seed))!
        }
    }
}
