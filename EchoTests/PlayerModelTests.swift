// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
struct PlayerModelTests {

    @Test("PlayerModel initializes with default services")
    func initDefaults() {
        let model = PlayerModel()

        #expect(model.isPlaying == false)
        #expect(model.currentTitle == "No track selected")
        #expect(model.currentPlaybackTime == 0)
    }

    @Test(
        "PlayerModel importEPUB preserves the source EPUB file when imported from the same folder")
    func importEPUBPreservesSourceWhenSameFolder() throws {
        let model = PlayerModel()
        let db = try DatabaseService(inMemory: ())
        model.databaseService = db

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        model.folderURL = tmpDir

        // Create a fake EPUB file inside the folder
        let epubURL = tmpDir.appendingPathComponent("test.epub")
        try Data("fake epub content".utf8).write(to: epubURL)

        // Verify the file exists initially
        #expect(FileManager.default.fileExists(atPath: epubURL.path))

        // Trigger importEPUB from the exact file location
        model.importEPUB(from: epubURL)

        // Verify the file was NOT deleted!
        #expect(FileManager.default.fileExists(atPath: epubURL.path))
    }

    @Test(
        "PlayerModel importEPUB deletes other EPUBs and copies new one when imported from outside folder"
    )
    func importEPUBDeletesOtherEPUBs() async throws {
        let model = PlayerModel()
        let db = try DatabaseService(inMemory: ())
        model.databaseService = db

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        model.folderURL = tmpDir

        // Create an existing epub in the folder (which should be deleted)
        let oldEpubURL = tmpDir.appendingPathComponent("old.epub")
        try Data("old epub content".utf8).write(to: oldEpubURL)

        // Create source epub outside the folder
        let outerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outerDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outerDir) }

        let sourceEpubURL = outerDir.appendingPathComponent("new.epub")
        try Data("new epub content".utf8).write(to: sourceEpubURL)

        // Trigger importEPUB
        model.importEPUB(from: sourceEpubURL)

        // Wait for asynchronous import task to finish
        let destinationURL = tmpDir.appendingPathComponent("new.epub")
        let start = Date()
        while !FileManager.default.fileExists(atPath: destinationURL.path)
            && Date().timeIntervalSince(start) < 1.0
        {
            try await Task.sleep(for: .milliseconds(10))
        }

        // Verify old EPUB is deleted to ensure a single companion document
        #expect(!FileManager.default.fileExists(atPath: oldEpubURL.path))

        // Verify new EPUB is copied into folder
        #expect(FileManager.default.fileExists(atPath: destinationURL.path))

        // Verify source EPUB at original location is NOT deleted
        #expect(FileManager.default.fileExists(atPath: sourceEpubURL.path))
    }

    @Test("hasPreviousChapter / hasNextChapter reflect chapter bounds")
    func chapterNavBoundsHelpers() {
        let model = PlayerModel()

        // No chapters → both false (single-chapter / marker-less book).
        #expect(model.hasPreviousChapter == false)
        #expect(model.hasNextChapter == false)

        // Three chapters, positioned at the first chapter.
        model.state.chapters = [
            Chapter(index: 0, title: "One", startSeconds: 0, endSeconds: 10),
            Chapter(index: 1, title: "Two", startSeconds: 10, endSeconds: 20),
            Chapter(index: 2, title: "Three", startSeconds: 20, endSeconds: 30),
        ]
        model.state.currentChapterIndex = 0
        #expect(model.hasPreviousChapter == false)
        #expect(model.hasNextChapter == true)

        // Middle chapter → both directions available.
        model.state.currentChapterIndex = 1
        #expect(model.hasPreviousChapter == true)
        #expect(model.hasNextChapter == true)

        // Last chapter → only previous.
        model.state.currentChapterIndex = 2
        #expect(model.hasPreviousChapter == true)
        #expect(model.hasNextChapter == false)

        // chapters present but index unresolved (nil) → treated as index 0.
        model.state.currentChapterIndex = nil
        #expect(model.hasPreviousChapter == false)
        #expect(model.hasNextChapter == true)
    }
}
