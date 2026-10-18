// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

/// Anchors `Bundle(for:)` lookup of the zipped `minimal-book.epub` fixture.
/// The merge path needs a real ZIP archive: `EPUBImportCoordinator` rejects
/// directory sources, so `TestEPUBFixture`'s expanded layout can't be used.
private final class ReadAlongMergeFixtureLocator {}

@MainActor
struct ReadAlongMergeServiceTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func zippedFixtureURL() throws -> URL {
        try #require(
            Bundle(for: ReadAlongMergeFixtureLocator.self)
                .url(forResource: "minimal-book", withExtension: "epub"),
            "minimal-book.epub is missing from the EchoTests bundle resources"
        )
    }

    @Test("Merging a sibling epub imports its text under the audio book's id")
    func mergeImportsTextUnderAudioID() async throws {
        let db = try DatabaseService(inMemory: ())
        let fm = FileManager.default

        // Both books are direct-open (no library root): scopedRoot is nil and
        // ambient temp-dir access covers the file operations.
        let audioDir = try makeTempDir()
        defer { try? fm.removeItem(at: audioDir) }
        let textDir = try makeTempDir()
        defer { try? fm.removeItem(at: textDir) }

        let textEPUB = textDir.appendingPathComponent("minimal-book.epub")
        try fm.copyItem(at: zippedFixtureURL(), to: textEPUB)

        let dao = AudiobookDAO(db: db.writer)
        let audio = AudiobookRecord(
            id: audioDir.absoluteString, title: "Dune", author: "Frank Herbert",
            duration: 100, fileCount: 1, addedAt: "2026-07-10T00:00:00Z", isAvailable: true)
        let text = AudiobookRecord(
            id: textDir.absoluteString, title: "Dune", author: nil,
            duration: 0, fileCount: 0, addedAt: "2026-07-10T00:00:01Z", isAvailable: true)
        try dao.save(audio)
        try dao.save(text)

        let service = ReadAlongMergeService(db: db)
        #expect(service.hasReadAlongText(audio.id) == false)

        try await service.merge(
            text: text, intoAudio: audio, libraryService: LibraryService(db: db))

        // Blocks are keyed under the AUDIO book's id, and the first/last
        // fallback anchors exist (duration was 100, no sidecar/CloudKit).
        let blocks = try EPubBlockDAO(db: db.writer).visibleBlocks(for: audio.id)
        #expect(!blocks.isEmpty)
        #expect(service.hasReadAlongText(audio.id))
        let anchors = try AlignmentAnchorDAO(db: db.writer).anchors(for: audio.id)
        #expect(!anchors.isEmpty)

        // The epub was copied into the audio folder.
        let destination = audioDir.appendingPathComponent("minimal-book.epub")
        #expect(fm.fileExists(atPath: destination.path))

        // The standalone text row and its file survive untouched.
        #expect(try dao.get(text.id) != nil)
        #expect(fm.fileExists(atPath: textEPUB.path))
        #expect(try EPubBlockDAO(db: db.writer).visibleBlocks(for: text.id).isEmpty)
    }

    @Test("Merge throws a descriptive error when the text folder has no epub")
    func mergeThrowsWhenTextFolderHasNoEPUB() async throws {
        let db = try DatabaseService(inMemory: ())
        let fm = FileManager.default

        let audioDir = try makeTempDir()
        defer { try? fm.removeItem(at: audioDir) }
        let textDir = try makeTempDir()
        defer { try? fm.removeItem(at: textDir) }

        let audio = AudiobookRecord(
            id: audioDir.absoluteString, title: "Dune", author: nil,
            duration: 100, fileCount: 1, addedAt: "2026-07-10T00:00:00Z", isAvailable: true)
        let text = AudiobookRecord(
            id: textDir.absoluteString, title: "Dune", author: nil,
            duration: 0, fileCount: 0, addedAt: "2026-07-10T00:00:01Z", isAvailable: true)

        let service = ReadAlongMergeService(db: db)
        do {
            try await service.merge(
                text: text, intoAudio: audio, libraryService: LibraryService(db: db))
            Issue.record("Expected merge to throw when the text folder has no epub.")
        } catch let error as ReadAlongMergeService.MergeError {
            guard case .epubNotFound = error else {
                Issue.record("Expected epubNotFound, got \(error).")
                return
            }
            #expect(error.errorDescription?.isEmpty == false)
        } catch {
            Issue.record("Expected MergeError, got \(error).")
        }
        #expect(try EPubBlockDAO(db: db.writer).visibleBlocks(for: audio.id).isEmpty)
    }

    @Test("Merge rejects an expanded epub directory with an actionable error")
    func mergeRejectsExpandedEPUBDirectory() async throws {
        let db = try DatabaseService(inMemory: ())
        let fm = FileManager.default

        let audioDir = try makeTempDir()
        defer { try? fm.removeItem(at: audioDir) }
        let textDir = try makeTempDir()
        defer { try? fm.removeItem(at: textDir) }

        // An expanded ".epub"-named directory inside the text folder — the v1
        // merge supports zipped epubs only.
        let expanded = textDir.appendingPathComponent("expanded.epub", isDirectory: true)
        try fm.createDirectory(at: expanded, withIntermediateDirectories: true)

        let audio = AudiobookRecord(
            id: audioDir.absoluteString, title: "Dune", author: nil,
            duration: 100, fileCount: 1, addedAt: "2026-07-10T00:00:00Z", isAvailable: true)
        let text = AudiobookRecord(
            id: textDir.absoluteString, title: "Dune", author: nil,
            duration: 0, fileCount: 0, addedAt: "2026-07-10T00:00:01Z", isAvailable: true)

        let service = ReadAlongMergeService(db: db)
        do {
            try await service.merge(
                text: text, intoAudio: audio, libraryService: LibraryService(db: db))
            Issue.record("Expected merge to reject the expanded epub directory.")
        } catch let error as ReadAlongMergeService.MergeError {
            guard case .expandedEPUBUnsupported = error else {
                Issue.record("Expected expandedEPUBUnsupported, got \(error).")
                return
            }
            #expect(error.errorDescription?.isEmpty == false)
        } catch {
            Issue.record("Expected MergeError, got \(error).")
        }
    }
}
