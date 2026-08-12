// SPDX-License-Identifier: GPL-3.0-or-later
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
        let fixture = try ABSImportProgressFixture(
            entries: (0..<50).map { ("book-\($0).m4b", String(repeating: "a", count: 1024)) })
        let importTask = Task {
            try await fixture.importer.prepareLocalFolder(for: fixture.item) {
                fixture.extractionStarted =
                    fixture.extractionStarted
                    || ($0.stage == .extracting && $0.completedUnits > 0)
            }
        }

        while !fixture.extractionStarted {
            await Task.yield()
        }
        importTask.cancel()

        do {
            _ = try await importTask.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Wrong error: \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.finalFolder.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.stagingFolder.path))
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
        #expect(!FileManager.default.fileExists(atPath: fixture.stagingFolder.path))
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
    var extractionStarted = false

    var finalFolder: URL { FileLocations.absLibraryDirectory(remoteItemID: item.id) }
    var stagingFolder: URL { FileLocations.absImportStagingDirectory(remoteItemID: item.id) }

    convenience init(entries: [(String, String)]) throws {
        try self.init(downloadData: Self.makeZip(entries: entries))
    }

    init(downloadData: Data) throws {
        let remoteItemID = "progress-item-\(UUID().uuidString)"
        serverID = "progress-server-\(UUID().uuidString)"
        scope = "progress-scope-\(UUID().uuidString)"
        tokens = ABSTokenStore(serverID: serverID)
        tokens.accessToken = "access"
        db = try DatabaseService(inMemory: ())
        item = try Self.makeItem(id: remoteItemID)

        URLProtocolStub.reset(scope: scope)
        URLProtocolStub.stub(
            scope: scope,
            pathSuffix: "/download",
            status: 200,
            data: downloadData,
            headers: ["Content-Type": "application/zip"])
        let service = AudiobookshelfService(
            baseURL: URL(string: "http://abs.test")!,
            tokens: tokens,
            session: URLProtocolStub.makeSession(scope: scope))
        importer = ABSImportService(service: service, db: db, serverID: serverID)

        try? FileManager.default.removeItem(at: finalFolder)
        try? FileManager.default.removeItem(at: stagingFolder)
    }

    isolated deinit {
        try? FileManager.default.removeItem(at: finalFolder)
        try? FileManager.default.removeItem(at: stagingFolder)
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

    private nonisolated static func makeItem(id: String) throws -> ABSLibraryItem {
        let json = """
            {"id":"\(id)","libraryId":"library","media":{"duration":60,
             "metadata":{"title":"Test Book","author":"Test Author"}}}
            """
        return try JSONDecoder().decode(ABSLibraryItem.self, from: Data(json.utf8))
    }
}
