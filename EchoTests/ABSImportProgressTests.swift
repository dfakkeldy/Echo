// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import GRDB
import Testing
import ZIPFoundation

@testable import Echo

@MainActor
struct ABSImportProgressTests {
    @Test func successReportsOrderedStagesAndReturnsVerifiedBook() async throws {
        let fixture = try ABSImportProgressFixture(entries: [("book.m4b", "audio")])
        var updates: [ABSImportProgress] = []

        let book = try await fixture.importer.prepareLocalFolder(for: fixture.item) {
            updates.append($0)
        }

        let stages = updates.map(\.stage)
        let indices = [
            ABSImportStage.downloading, .extracting, .validating, .addingToEcho, .added,
        ].compactMap { stages.firstIndex(of: $0) }
        #expect(indices.count == 5)
        #expect(indices == indices.sorted())
        #expect(book.remoteItemID == fixture.item.id)
        #expect(ABSLocalImportStatus.hasSupportedRootContent(at: book.folderURL))
        let record = try AudiobookDAO(db: fixture.db.writer).get(book.folderURL.absoluteString)
        #expect(record?.serverID == fixture.serverID)
        #expect(record?.remoteItemID == fixture.item.id)
    }

    @Test func extractionProgressUsesMonotonicDeclaredBytes() async throws {
        let fixture = try ABSImportProgressFixture(
            entries: [("one.m4b", "abc"), ("notes.epub", "1234567")])
        var updates: [ABSImportProgress] = []

        _ = try await fixture.importer.prepareLocalFolder(for: fixture.item) {
            updates.append($0)
        }

        let extraction = updates.filter { $0.stage == .extracting && $0.completedUnits > 0 }
        #expect(extraction.map(\.completedUnits) == [3, 10])
        #expect(extraction.map(\.totalUnits) == [10, 10])
    }

    @Test func nestedOnlyAudioFailsAtValidation() async throws {
        let fixture = try ABSImportProgressFixture(entries: [("wrapper/book.m4b", "audio")])

        do {
            _ = try await fixture.importer.prepareLocalFolder(for: fixture.item) { _ in }
            Issue.record("Expected nested-only audio to fail validation")
        } catch let failure as ABSImportFailure {
            #expect(failure.stage == .validating)
            #expect(!failure.isRetryable)
        } catch {
            Issue.record("Wrong error: \(error)")
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.finalFolder.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.stagingFolder.path))
    }

    @Test func corruptZipFailsAtExtraction() async throws {
        let fixture = try ABSImportProgressFixture(downloadData: Data("not-a-zip".utf8))

        do {
            _ = try await fixture.importer.prepareLocalFolder(for: fixture.item) { _ in }
            Issue.record("Expected corrupt ZIP to fail extraction")
        } catch let failure as ABSImportFailure {
            #expect(failure.stage == .extracting)
            #expect(failure.isRetryable)
        } catch {
            Issue.record("Wrong error: \(error)")
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.finalFolder.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.stagingFolder.path))
    }

    @Test func cancellationDuringExtractionCleansStagingAndDoesNotPublish() async throws {
        let extractionGate = ABSImportSuspensionGate()
        let fixture = try ABSImportProgressFixture(
            entries: [("book.m4b", "audio")],
            afterExtractedEntry: { await extractionGate.suspend() })
        let importTask = Task {
            try await fixture.importer.prepareLocalFolder(for: fixture.item) { _ in }
        }

        await extractionGate.waitUntilSuspended()
        let stagedResidue = try #require(
            fixture.importResidues.first { $0.lastPathComponent.contains("staging") })
        #expect(FileManager.default.fileExists(atPath: stagedResidue.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.finalFolder.path))
        importTask.cancel()
        await extractionGate.release()

        do {
            _ = try await importTask.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Wrong error: \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.finalFolder.path))
        #expect(!FileManager.default.fileExists(atPath: stagedResidue.path))
        #expect(fixture.importResidues.isEmpty)
    }

    @Test func cancellationAfterPersistenceReturnsCommittedSuccess() async throws {
        let persistenceGate = ABSImportSuspensionGate()
        let fixture = try ABSImportProgressFixture(
            entries: [("book.m4b", "audio")],
            afterPersistence: { await persistenceGate.suspend() })
        var updates: [ABSImportProgress] = []
        let importTask = Task {
            try await fixture.importer.prepareLocalFolder(for: fixture.item) {
                updates.append($0)
            }
        }

        await persistenceGate.waitUntilSuspended()
        importTask.cancel()
        await persistenceGate.release()

        let book = try await importTask.value
        #expect(book.remoteItemID == fixture.item.id)
        #expect(updates.last?.stage == .added)
        #expect(ABSLocalImportStatus.hasSupportedRootContent(at: book.folderURL))
        #expect(try AudiobookDAO(db: fixture.db.writer).get(book.folderURL.absoluteString) != nil)
    }

    @Test func databaseFailureReportsAddingStageAndPreservesCompletedReimport() async throws {
        let fixture = try ABSImportProgressFixture(entries: [("new.m4b", "new")])
        try FileManager.default.createDirectory(
            at: fixture.finalFolder, withIntermediateDirectories: true)
        let existingFile = fixture.finalFolder.appending(path: "existing.m4b")
        let existingBytes = Data("existing".utf8)
        try existingBytes.write(to: existingFile)
        let previous = AudiobookRecord(
            id: fixture.finalFolder.absoluteString,
            title: "Existing",
            author: nil,
            duration: 1,
            fileCount: 1,
            addedAt: "before",
            sourceType: "audiobookshelf",
            serverID: fixture.serverID,
            remoteItemID: fixture.item.id)
        try AudiobookDAO(db: fixture.db.writer).save(previous)
        try fixture.db.write { db in
            try db.execute(
                sql:
                    "CREATE TRIGGER fail_abs_import BEFORE UPDATE ON audiobook BEGIN SELECT RAISE(FAIL, 'test'); END"
            )
        }

        do {
            _ = try await fixture.importer.prepareLocalFolder(for: fixture.item) { _ in }
            Issue.record("Expected database failure")
        } catch let failure as ABSImportFailure {
            #expect(failure.stage == .addingToEcho)
            #expect(failure.isRetryable)
        } catch {
            Issue.record("Wrong error: \(error)")
        }

        #expect((try? Data(contentsOf: existingFile)) == existingBytes)
        let restored = try AudiobookDAO(db: fixture.db.writer).get(previous.id)
        #expect(restored?.title == "Existing")
        #expect(restored?.remoteItemID == fixture.item.id)
        #expect(!FileManager.default.fileExists(atPath: fixture.stagingFolder.path))
    }

    @Test func firstImportDatabaseFailureRemovesStagedLibraryCover() async throws {
        let newCover = Data([1, 2, 3, 4])
        let fixture = try ABSImportProgressFixture(
            entries: [("book.m4b", "audio")], coverData: newCover)
        try fixture.db.write { db in
            try db.execute(
                sql:
                    "CREATE TRIGGER fail_abs_import BEFORE INSERT ON audiobook BEGIN SELECT RAISE(FAIL, 'test'); END"
            )
        }

        let firstFailure = await fixture.captureFailure()

        #expect(firstFailure?.stage == .addingToEcho)
        #expect(!FileManager.default.fileExists(atPath: fixture.finalFolder.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.libraryCoverURL.path))
        #expect(fixture.coverResidues.isEmpty)
    }

    @Test func successfulCoverPublicationMatchesRecordAndFinalFolderCover() async throws {
        let cover = Data([4, 3, 2, 1])
        let fixture = try ABSImportProgressFixture(
            entries: [("book.m4b", "audio")], coverData: cover)

        let book = try await fixture.importer.prepareLocalFolder(for: fixture.item) { _ in }

        let persistedRecord = try AudiobookDAO(db: fixture.db.writer).get(
            book.folderURL.absoluteString)
        let record = try #require(persistedRecord)
        let coverArtPath = try #require(record.coverArtPath)
        let publishedCover = FileLocations.libraryCoversDirectory.appending(path: coverArtPath)
        #expect((try? Data(contentsOf: book.folderURL.appending(path: "cover.jpg"))) == cover)
        #expect((try? Data(contentsOf: publishedCover)) == cover)
    }

    @Test func failedFirstImportDeletionKeepsRecoveryTruthAndUsesRollbackMessage() async throws {
        struct RemovalFailure: Error {}
        let fixture = try ABSImportProgressFixture(
            entries: [("book.m4b", "audio")],
            beforeRemoveNewFolder: { throw RemovalFailure() })
        try fixture.db.write { db in
            try db.execute(
                sql:
                    "CREATE TRIGGER fail_abs_import BEFORE INSERT ON audiobook BEGIN SELECT RAISE(FAIL, 'test'); END"
            )
        }

        let failure = await fixture.captureFailure()

        #expect(failure?.stage == .addingToEcho)
        #expect(failure?.message.localizedCaseInsensitiveContains("recovery") == true)
        #expect(FileManager.default.fileExists(atPath: fixture.finalFolder.path))
    }

    @Test func failedReimportRestoresOldLibraryCoverAndUsesPreservedCopyMessage() async throws {
        let oldCover = Data([9, 9, 9])
        let newCover = Data([1, 2, 3])
        let fixture = try ABSImportProgressFixture(
            entries: [("new.m4b", "new")], coverData: newCover)
        try fixture.installExistingImport(coverData: oldCover)
        try fixture.db.write { db in
            try db.execute(
                sql:
                    "CREATE TRIGGER fail_abs_import BEFORE UPDATE ON audiobook BEGIN SELECT RAISE(FAIL, 'test'); END"
            )
        }

        let reimportFailure = await fixture.captureFailure()

        #expect(reimportFailure?.stage == .addingToEcho)
        #expect((try? Data(contentsOf: fixture.libraryCoverURL)) == oldCover)
        #expect(fixture.coverResidues.isEmpty)

        let firstImport = try ABSImportProgressFixture(entries: [("book.m4b", "audio")])
        try firstImport.db.write { db in
            try db.execute(
                sql:
                    "CREATE TRIGGER fail_abs_import BEFORE INSERT ON audiobook BEGIN SELECT RAISE(FAIL, 'test'); END"
            )
        }
        let firstFailure = await firstImport.captureFailure()
        #expect(firstFailure?.message != reimportFailure?.message)
    }

    @Test func failedFolderRestorationKeepsRecoverableBackup() async throws {
        struct RestoreFailure: Error {}
        let fixture = try ABSImportProgressFixture(
            entries: [("new.m4b", "new")],
            beforeRestoreExistingFolder: { throw RestoreFailure() })
        try fixture.installExistingImport(coverData: nil)
        try fixture.db.write { db in
            try db.execute(
                sql:
                    "CREATE TRIGGER fail_abs_import BEFORE UPDATE ON audiobook BEGIN SELECT RAISE(FAIL, 'test'); END"
            )
        }

        let failure = await fixture.captureFailure()

        #expect(failure?.stage == .addingToEcho)
        let backup = try #require(
            fixture.importResidues.first { $0.lastPathComponent.contains("backup") })
        #expect(
            (try? String(contentsOf: backup.appending(path: "existing.m4b"), encoding: .utf8))
                == "existing")
    }
}

@MainActor
private final class ABSImportProgressFixture {
    let db: DatabaseService
    let importer: ABSImportService
    let item: ABSLibraryItem
    let serverID: String
    let scope: String
    let tokens: ABSTokenStore

    var finalFolder: URL { FileLocations.absLibraryDirectory(remoteItemID: item.id) }
    var stagingFolder: URL { FileLocations.absImportStagingDirectory(remoteItemID: item.id) }
    var libraryCoverURL: URL {
        FileLocations.libraryCoversDirectory.appending(path: Self.coverFilename(for: finalFolder))
    }
    var importResidues: [URL] {
        let siblings =
            (try? FileManager.default.contentsOfDirectory(
                at: finalFolder.deletingLastPathComponent(),
                includingPropertiesForKeys: nil)) ?? []
        return siblings.filter {
            $0.standardizedFileURL != finalFolder.standardizedFileURL
                && $0.lastPathComponent.contains(item.id)
        }
    }
    var coverResidues: [URL] {
        let prefix = libraryCoverURL.deletingPathExtension().lastPathComponent
        let siblings =
            (try? FileManager.default.contentsOfDirectory(
                at: FileLocations.libraryCoversDirectory,
                includingPropertiesForKeys: nil)) ?? []
        return siblings.filter {
            $0.standardizedFileURL != libraryCoverURL.standardizedFileURL
                && $0.lastPathComponent.contains(prefix)
        }
    }

    convenience init(
        entries: [(String, String)],
        coverData: Data? = nil,
        afterExtractedEntry: @escaping @Sendable () async -> Void = {},
        afterPersistence: @escaping @Sendable () async -> Void = {},
        beforeRestoreExistingFolder: @escaping @Sendable () throws -> Void = {},
        beforeRemoveNewFolder: @escaping @Sendable () throws -> Void = {}
    ) throws {
        try self.init(
            downloadData: Self.makeZip(entries: entries),
            coverData: coverData,
            afterExtractedEntry: afterExtractedEntry,
            afterPersistence: afterPersistence,
            beforeRestoreExistingFolder: beforeRestoreExistingFolder,
            beforeRemoveNewFolder: beforeRemoveNewFolder)
    }

    init(
        downloadData: Data,
        coverData: Data? = nil,
        afterExtractedEntry: @escaping @Sendable () async -> Void = {},
        afterPersistence: @escaping @Sendable () async -> Void = {},
        beforeRestoreExistingFolder: @escaping @Sendable () throws -> Void = {},
        beforeRemoveNewFolder: @escaping @Sendable () throws -> Void = {}
    ) throws {
        let remoteItemID = "progress-item-\(UUID().uuidString)"
        serverID = "progress-server-\(UUID().uuidString)"
        scope = "progress-scope-\(UUID().uuidString)"
        tokens = ABSTokenStore(serverID: serverID)
        tokens.accessToken = "access"
        db = try DatabaseService(inMemory: ())
        item = try Self.makeItem(id: remoteItemID, hasCover: coverData != nil)

        URLProtocolStub.reset(scope: scope)
        URLProtocolStub.stub(
            scope: scope,
            pathSuffix: "/download",
            status: 200,
            data: downloadData,
            headers: ["Content-Type": "application/zip"])
        if let coverData {
            URLProtocolStub.stub(
                scope: scope,
                pathSuffix: "/cover",
                status: 200,
                data: coverData,
                headers: ["Content-Type": "image/jpeg"])
        }
        let service = AudiobookshelfService(
            baseURL: URL(string: "http://abs.test")!,
            tokens: tokens,
            session: URLProtocolStub.makeSession(scope: scope))
        importer = ABSImportService(
            service: service,
            db: db,
            serverID: serverID,
            afterExtractedEntry: afterExtractedEntry,
            afterPersistence: afterPersistence,
            beforeRestoreExistingFolder: beforeRestoreExistingFolder,
            beforeRemoveNewFolder: beforeRemoveNewFolder)

        try? FileManager.default.removeItem(at: finalFolder)
        try? FileManager.default.removeItem(at: stagingFolder)
        try? FileManager.default.removeItem(at: libraryCoverURL)
    }

    isolated deinit {
        let importResidues = self.importResidues
        let coverResidues = self.coverResidues
        try? FileManager.default.removeItem(at: finalFolder)
        try? FileManager.default.removeItem(at: stagingFolder)
        try? FileManager.default.removeItem(at: libraryCoverURL)
        // Recovery backups intentionally survive a failed restore so the user can recover them.
        // Test teardown owns its isolated fixture and removes them here.
        for residue in importResidues + coverResidues {
            try? FileManager.default.removeItem(at: residue)
        }
        tokens.clear()
        URLProtocolStub.finish(scope: scope)
    }

    private nonisolated static func makeZip(entries: [(String, String)]) throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "abs-progress-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = try Archive(url: url, accessMode: .create)
        for (path, contents) in entries {
            let data = Data(contents.utf8)
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count)
            ) { position, size in
                let start = Int(position)
                return data.subdata(in: start..<min(start + size, data.count))
            }
        }
        return try Data(contentsOf: url)
    }

    func captureFailure() async -> ABSImportFailure? {
        do {
            _ = try await importer.prepareLocalFolder(for: item) { _ in }
            Issue.record("Expected import failure")
            return nil
        } catch let failure as ABSImportFailure {
            return failure
        } catch {
            Issue.record("Wrong error: \(error)")
            return nil
        }
    }

    func installExistingImport(coverData: Data?) throws {
        try FileManager.default.createDirectory(at: finalFolder, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: finalFolder.appending(path: "existing.m4b"))
        let coverFilename = coverData.map { _ in Self.coverFilename(for: finalFolder) }
        if let coverData {
            try FileManager.default.createDirectory(
                at: FileLocations.libraryCoversDirectory, withIntermediateDirectories: true)
            try coverData.write(to: libraryCoverURL)
        }
        try AudiobookDAO(db: db.writer).save(
            AudiobookRecord(
                id: finalFolder.absoluteString,
                title: "Existing",
                author: nil,
                duration: 1,
                fileCount: 1,
                addedAt: "before",
                sourceType: "audiobookshelf",
                serverID: serverID,
                remoteItemID: item.id,
                coverArtPath: coverFilename))
    }

    private nonisolated static func coverFilename(for folder: URL) -> String {
        SHA256.hash(data: Data(folder.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined() + ".jpg"
    }

    private static func makeItem(id: String, hasCover: Bool) throws -> ABSLibraryItem {
        let coverJSON = hasCover ? #", "coverPath":"/metadata/items/cover.jpg""# : ""
        let json = """
            {"id":"\(id)","libraryId":"library","media":{"duration":60,
             "metadata":{"title":"Test Book","author":"Test Author"}\(coverJSON)}}
            """
        return try JSONDecoder().decode(ABSLibraryItem.self, from: Data(json.utf8))
    }
}

private actor ABSImportSuspensionGate {
    private var suspended = false
    private var released = false
    private var suspendedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        suspended = true
        suspendedWaiters.forEach { $0.resume() }
        suspendedWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilSuspended() async {
        guard !suspended else { return }
        await withCheckedContinuation { suspendedWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}
