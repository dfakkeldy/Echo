// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import ZIPFoundation

@testable import Echo

@MainActor
@Suite struct ABSImportServiceTests {
    /// Builds a one-file zip on disk and returns its bytes.
    private func makeZip(entry: String, contents: String) throws -> Data {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mkzip-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let archive = try Archive(url: tmp, accessMode: .create)
        let data = Data(contents.utf8)
        try archive.addEntry(with: entry, type: .file, uncompressedSize: Int64(data.count)) {
            position, size in
            let start = Int(position)
            return data.subdata(in: start..<min(start + size, data.count))
        }
        return try Data(contentsOf: tmp)
    }

    private func makeItem(id: String) -> ABSLibraryItem {
        // Decode a minimal item so titles/topics are populated as the real model expects.
        let json = """
            {"id":"\(id)","libraryId":"lib1","media":{"duration":1200,"tags":["studied"],
             "metadata":{"title":"Hungry Ghosts","author":"Gabor Mate","genres":["Psychology"]}}}
            """
        return try! JSONDecoder().decode(ABSLibraryItem.self, from: Data(json.utf8))
    }

    @Test func prepareLocalFolderDownloadsUnzipsAndStamps() async throws {
        URLProtocolStub.reset()
        let dbService = try DatabaseService(inMemory: ())
        let tokens = ABSTokenStore(serverID: "imp-\(UUID().uuidString)")
        tokens.accessToken = "acc"
        let svc = AudiobookshelfService(
            baseURL: URL(string: "http://h:13378")!, tokens: tokens,
            session: URLProtocolStub.makeSession())
        let zipBytes = try makeZip(entry: "book.m4b", contents: "fake-audio-bytes")
        URLProtocolStub.stub(
            pathSuffix: "/download", status: 200, data: zipBytes,
            headers: ["Content-Type": "application/zip"])

        let item = makeItem(id: "item-\(UUID().uuidString)")
        let importer = ABSImportService(service: svc, db: dbService, serverID: "srvX")
        let folder = try await importer.prepareLocalFolder(for: item)
        defer { try? FileManager.default.removeItem(at: folder) }

        // 1) the zip was extracted into the folder
        let extracted = folder.appendingPathComponent("book.m4b")
        #expect(FileManager.default.fileExists(atPath: extracted.path))
        // 2) the temp zip was cleaned up
        #expect(
            !FileManager.default.fileExists(
                atPath: folder.appendingPathComponent("__abs_download.zip").path))
        // 3) the row was stamped with ABS provenance + the real title/author/topics
        let row = try AudiobookDAO(db: dbService.writer).get(folder.absoluteString)
        #expect(row?.sourceType == "audiobookshelf")
        #expect(row?.serverID == "srvX")
        #expect(row?.remoteItemID == item.id)
        #expect(row?.title == "Hungry Ghosts")
        #expect(row?.author == "Gabor Mate")
        #expect(row?.topicsJSON?.contains("Psychology") == true)
    }
}
