// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing
import ZIPFoundation

@testable import Echo

@MainActor
@Suite(.serialized) struct ABSImportServiceTests {
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

    private func makeZipWithDeclaredUncompressedSize(entry: String, size: UInt32) -> Data {
        var data = Data()
        let name = Data(entry.utf8)

        func appendUInt16(_ value: UInt16) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        func appendUInt32(_ value: UInt32) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        appendUInt32(0x0403_4B50)  // local file header
        appendUInt16(20)
        appendUInt16(0)
        appendUInt16(0)
        appendUInt16(0)
        appendUInt16(0)
        appendUInt32(0)
        appendUInt32(0)
        appendUInt32(size)
        appendUInt16(UInt16(name.count))
        appendUInt16(0)
        data.append(name)

        let centralDirectoryOffset = UInt32(data.count)
        appendUInt32(0x0201_4B50)  // central directory header
        appendUInt16(20)
        appendUInt16(20)
        appendUInt16(0)
        appendUInt16(0)
        appendUInt16(0)
        appendUInt16(0)
        appendUInt32(0)
        appendUInt32(0)
        appendUInt32(size)
        appendUInt16(UInt16(name.count))
        appendUInt16(0)
        appendUInt16(0)
        appendUInt16(0)
        appendUInt16(0)
        appendUInt32(0)
        appendUInt32(0)
        data.append(name)

        let centralDirectorySize = UInt32(data.count) - centralDirectoryOffset
        appendUInt32(0x0605_4B50)  // end of central directory
        appendUInt16(0)
        appendUInt16(0)
        appendUInt16(1)
        appendUInt16(1)
        appendUInt32(centralDirectorySize)
        appendUInt32(centralDirectoryOffset)
        appendUInt16(0)
        return data
    }

    private func makeItem(id: String, coverPath: String? = nil) throws -> ABSLibraryItem {
        // Decode a minimal item so titles/topics are populated as the real model expects.
        let coverJSON = coverPath.map { #","coverPath":"\#($0)""# } ?? ""
        let json = """
            {"id":"\(id)","libraryId":"lib1","media":{"duration":1200,"tags":["studied"],
             "metadata":{"title":"Hungry Ghosts","author":"Gabor Mate","genres":["Psychology"]}\(coverJSON)}}
            """
        return try JSONDecoder().decode(ABSLibraryItem.self, from: Data(json.utf8))
    }

    private func makeService(serverID: String = "imp-\(UUID().uuidString)") -> AudiobookshelfService {
        URLProtocolStub.reset()
        let tokens = ABSTokenStore(serverID: serverID)
        tokens.accessToken = "acc"
        return AudiobookshelfService(
            baseURL: URL(string: "http://h:13378")!, tokens: tokens,
            session: URLProtocolStub.makeSession())
    }

    private func itemSpecificImportResidues(remoteItemID: String) -> [URL] {
        let finalFolder = FileLocations.absLibraryDirectory(remoteItemID: remoteItemID)
        let parent = finalFolder.deletingLastPathComponent()
        let siblings =
            (try? FileManager.default.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: nil,
                options: []
            )) ?? []
        return siblings.filter {
            $0.standardizedFileURL != finalFolder.standardizedFileURL
                && $0.lastPathComponent.contains(remoteItemID)
        }
    }

    private func source(_ relativePath: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory
                .deletingLastPathComponent()
                .appending(path: relativePath)
            if FileManager.default.fileExists(atPath: candidate.path),
                let content = try? String(contentsOf: candidate, encoding: .utf8)
            {
                return content
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    @Test func itemSpecificImportResiduesReportsHiddenStagingAndBackupFolders() throws {
        let remoteItemID = "item-\(UUID().uuidString)"
        let finalFolder = FileLocations.absLibraryDirectory(remoteItemID: remoteItemID)
        let parent = finalFolder.deletingLastPathComponent()
        let stagingFolder = FileLocations.absImportStagingDirectory(remoteItemID: remoteItemID)
        let backupFolder = parent.appending(
            path: ".\(remoteItemID)-backup-test",
            directoryHint: .isDirectory)

        try? FileManager.default.removeItem(at: stagingFolder)
        try? FileManager.default.removeItem(at: backupFolder)
        defer {
            try? FileManager.default.removeItem(at: stagingFolder)
            try? FileManager.default.removeItem(at: backupFolder)
        }

        try FileManager.default.createDirectory(at: stagingFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)

        let residues = itemSpecificImportResidues(remoteItemID: remoteItemID)
            .map(\.lastPathComponent)

        #expect(residues.contains(stagingFolder.lastPathComponent))
        #expect(residues.contains(backupFolder.lastPathComponent))
    }

    @Test func commitPreparedFolderUsesFoundationAtomicReplacementForExistingFolders() throws {
        let src = try source("EchoCore/Services/Audiobookshelf/ABSImportService.swift")

        #expect(src.contains("replaceItem("))
        #expect(!src.contains("moveItem(at: finalFolder, to: backupFolder)"))
        #expect(!src.contains("movedExistingToBackup"))
    }

    @Test func prepareLocalFolderDownloadsUnzipsAndStamps() async throws {
        let dbService = try DatabaseService(inMemory: ())
        let svc = makeService()
        let zipBytes = try makeZip(entry: "book.m4b", contents: "fake-audio-bytes")
        URLProtocolStub.stub(
            pathSuffix: "/download", status: 200, data: zipBytes,
            headers: ["Content-Type": "application/zip"])

        let item = try makeItem(id: "item-\(UUID().uuidString)")
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

    @Test func failedReimportPreservesExistingCompletedFolder() async throws {
        let dbService = try DatabaseService(inMemory: ())
        let svc = makeService()
        URLProtocolStub.stub(pathSuffix: "/download", status: 500, json: "{}")

        let item = try makeItem(id: "item-\(UUID().uuidString)")
        let folder = FileLocations.absLibraryDirectory(remoteItemID: item.id)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let existingFile = folder.appending(path: "existing.m4b")
        let existingData = Data("completed-local-import".utf8)
        try existingData.write(to: existingFile)
        defer { try? FileManager.default.removeItem(at: folder) }

        let importer = ABSImportService(service: svc, db: dbService, serverID: "srvX")
        await #expect {
            try await importer.prepareLocalFolder(for: item)
        } throws: { error in
            if case ABSError.http(500, _) = error { return true }
            return false
        }

        #expect((try? Data(contentsOf: existingFile)) == existingData)
        #expect(itemSpecificImportResidues(remoteItemID: item.id).isEmpty)
    }

    @Test func successfulReimportAtomicallyReplacesExistingFolderWithoutResidue() async throws {
        let dbService = try DatabaseService(inMemory: ())
        let svc = makeService()
        let zipBytes = try makeZip(entry: "new.m4b", contents: "new-import")
        URLProtocolStub.stub(
            pathSuffix: "/download", status: 200, data: zipBytes,
            headers: ["Content-Type": "application/zip"])

        let item = try makeItem(id: "item-\(UUID().uuidString)")
        let folder = FileLocations.absLibraryDirectory(remoteItemID: item.id)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let existingFile = folder.appending(path: "existing.m4b")
        try Data("old-import".utf8).write(to: existingFile)
        defer { try? FileManager.default.removeItem(at: folder) }

        let importer = ABSImportService(service: svc, db: dbService, serverID: "srvX")
        let importedFolder = try await importer.prepareLocalFolder(for: item)

        #expect(importedFolder.standardizedFileURL == folder.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: existingFile.path))
        #expect((try? String(contentsOf: folder.appending(path: "new.m4b"), encoding: .utf8)) == "new-import")
        #expect(itemSpecificImportResidues(remoteItemID: item.id).isEmpty)
    }

    @Test func failedReimportAfterFolderPublishRestoresExistingFolderAndCleansBackup() async throws {
        let dbService = try DatabaseService(inMemory: ())
        try dbService.write { db in try db.execute(sql: "DROP TABLE audiobook") }
        let svc = makeService()
        let zipBytes = try makeZip(entry: "new.m4b", contents: "new-import")
        URLProtocolStub.stub(
            pathSuffix: "/download", status: 200, data: zipBytes,
            headers: ["Content-Type": "application/zip"])

        let item = try makeItem(id: "item-\(UUID().uuidString)")
        let folder = FileLocations.absLibraryDirectory(remoteItemID: item.id)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let existingFile = folder.appending(path: "existing.m4b")
        let existingData = Data("completed-local-import".utf8)
        try existingData.write(to: existingFile)
        defer { try? FileManager.default.removeItem(at: folder) }

        let importer = ABSImportService(service: svc, db: dbService, serverID: "srvX")
        await #expect {
            try await importer.prepareLocalFolder(for: item)
        } throws: { _ in
            true
        }

        #expect((try? Data(contentsOf: existingFile)) == existingData)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "new.m4b").path))
        #expect(itemSpecificImportResidues(remoteItemID: item.id).isEmpty)
    }

    @Test func failedImportAfterExtractionCleansPartialStagingWithoutCreatingFinalFolder() async throws {
        let dbService = try DatabaseService(inMemory: ())
        try dbService.write { db in try db.execute(sql: "DROP TABLE audiobook") }
        let svc = makeService()
        let zipBytes = try makeZip(entry: "book.m4b", contents: "fake-audio-bytes")
        URLProtocolStub.stub(
            pathSuffix: "/download", status: 200, data: zipBytes,
            headers: ["Content-Type": "application/zip"])

        let item = try makeItem(id: "item-\(UUID().uuidString)")
        let folder = FileLocations.absLibraryDirectory(remoteItemID: item.id)
        try? FileManager.default.removeItem(at: folder)
        defer { try? FileManager.default.removeItem(at: folder) }

        let importer = ABSImportService(service: svc, db: dbService, serverID: "srvX")
        await #expect {
            try await importer.prepareLocalFolder(for: item)
        } throws: { _ in
            true
        }

        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(itemSpecificImportResidues(remoteItemID: item.id).isEmpty)
    }

    @Test func prepareLocalFolderRejectsWholeItemZipThatExceedsAudiobookBudget() async throws {
        let dbService = try DatabaseService(inMemory: ())
        let svc = makeService()
        let oversizedEntrySize = UInt32(
            ArchiveExtractionLimits.Budget.absWholeAudiobook.maxEntryBytes + 1)
        let zipBytes = makeZipWithDeclaredUncompressedSize(entry: "giant.m4b", size: oversizedEntrySize)
        URLProtocolStub.stub(
            pathSuffix: "/download", status: 200, data: zipBytes,
            headers: ["Content-Type": "application/zip"])

        let item = try makeItem(id: "item-\(UUID().uuidString)")
        let folder = FileLocations.absLibraryDirectory(remoteItemID: item.id)
        defer { try? FileManager.default.removeItem(at: folder) }

        let importer = ABSImportService(service: svc, db: dbService, serverID: "srvX")
        await #expect {
            try await importer.prepareLocalFolder(for: item)
        } throws: { error in
            error is ArchiveExtractionLimits.LimitError
        }
    }

    @Test func prepareLocalFolderDownloadsServerCoverIntoManagedFolder() async throws {
        let dbService = try DatabaseService(inMemory: ())
        let svc = makeService()
        let zipBytes = try makeZip(entry: "book.m4b", contents: "fake-audio-bytes")
        let coverBytes = Data([0xFF, 0xD8, 0xFF, 0xD9])
        URLProtocolStub.stub(
            pathSuffix: "/download", status: 200, data: zipBytes,
            headers: ["Content-Type": "application/zip"])
        URLProtocolStub.stub(
            pathSuffix: "/cover", status: 200, data: coverBytes,
            headers: ["Content-Type": "image/jpeg"])

        let item = try makeItem(id: "item-\(UUID().uuidString)", coverPath: "/metadata/items/cover.jpg")
        let importer = ABSImportService(service: svc, db: dbService, serverID: "srvX")
        let folder = try await importer.prepareLocalFolder(for: item)
        defer { try? FileManager.default.removeItem(at: folder) }

        let managedCover = folder.appending(path: "cover.jpg")
        #expect((try? Data(contentsOf: managedCover)) == coverBytes)
        let row = try AudiobookDAO(db: dbService.writer).get(folder.absoluteString)
        let coverArtPath = try #require(row?.coverArtPath)
        let libraryCover = FileLocations.libraryCoversDirectory.appending(path: coverArtPath)
        defer { try? FileManager.default.removeItem(at: libraryCover) }
        #expect((try? Data(contentsOf: libraryCover)) == coverBytes)
    }

    @Test func zipExtractionWorkIsDeclaredOffMainActor() throws {
        let src = try source("EchoCore/Services/Audiobookshelf/ABSImportService.swift")

        #expect(src.contains("@concurrent"))
        #expect(src.contains("extractWholeAudiobookArchive"))
        #expect(!src.contains("FileManager.default.unzipItem(at: zipURL, to: folder)"))
    }
}
