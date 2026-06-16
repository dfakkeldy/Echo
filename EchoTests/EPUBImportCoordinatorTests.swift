// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
import Foundation
@testable import Echo

@MainActor
struct EPUBImportCoordinatorTests {

    @Test("Same-folder import preserves the source EPUB file")
    func preservesSourceWhenSameFolder() async throws {
        let db = try DatabaseService(inMemory: ())

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let epubURL = tmpDir.appendingPathComponent("test.epub")
        try Data("fake epub content".utf8).write(to: epubURL)

        #expect(FileManager.default.fileExists(atPath: epubURL.path))

        await EPUBImportCoordinator.importEPUB(
            from: epubURL,
            to: tmpDir,
            databaseService: db,
            chapters: [],
            duration: nil
        )

        // Source must still exist — same-folder imports skip the copy.
        #expect(FileManager.default.fileExists(atPath: epubURL.path))
    }

    @Test("Outside-folder import copies EPUB into folder and preserves source")
    func copiesIntoFolderAndPreservesSource() async throws {
        let db = try DatabaseService(inMemory: ())

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Pre-existing EPUB in the folder should survive.
        let oldURL = tmpDir.appendingPathComponent("old.epub")
        try Data("old".utf8).write(to: oldURL)

        // Source EPUB outside the folder.
        let outerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outerDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outerDir) }

        let sourceURL = outerDir.appendingPathComponent("new.epub")
        try Data("new".utf8).write(to: sourceURL)

        await EPUBImportCoordinator.importEPUB(
            from: sourceURL,
            to: tmpDir,
            databaseService: db,
            chapters: [],
            duration: nil
        )

        // Old EPUB is cleaned up to ensure a single companion document.
        #expect(!FileManager.default.fileExists(atPath: oldURL.path))

        // New EPUB was copied in.
        let destURL = tmpDir.appendingPathComponent("new.epub")
        #expect(FileManager.default.fileExists(atPath: destURL.path))

        // Source at original location is preserved.
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    @Test("Overwrite replaces existing destination EPUB")
    func overwriteReplacesExistingDestination() async throws {
        let db = try DatabaseService(inMemory: ())

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Pre-existing file at destination with same name.
        let existingURL = tmpDir.appendingPathComponent("book.epub")
        try Data("old content".utf8).write(to: existingURL)

        // Source outside folder with same filename.
        let outerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outerDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outerDir) }

        let sourceURL = outerDir.appendingPathComponent("book.epub")
        try Data("new content".utf8).write(to: sourceURL)

        await EPUBImportCoordinator.importEPUB(
            from: sourceURL,
            to: tmpDir,
            databaseService: db,
            chapters: [],
            duration: nil
        )

        // Destination now holds the new content.
        #expect(FileManager.default.fileExists(atPath: existingURL.path))
        let content = try Data(contentsOf: existingURL)
        #expect(String(data: content, encoding: .utf8) == "new content")
    }
}
