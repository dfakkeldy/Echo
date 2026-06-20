// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct TextDocumentImportTests {

    private func stage(_ name: String, _ contents: String) throws -> (
        folder: URL, file: URL, id: String
    ) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("textimport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        try Data(contents.utf8).write(to: file)
        return (folder, file, folder.absoluteString)
    }

    @Test func markdownFileImportsAsAudioLessBookWithChapterZeroBlocks() async throws {
        let db = try DatabaseService(inMemory: ())
        let (folder, file, id) = try stage(
            "My Study Notes.md",
            "## Chapter One\n\nThe first **idea** to learn.\n\n### A Section\n\nDetail.\n\n## Chapter Two\n\nThe second idea."
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        // Mirror loadFolder's no-audio branch: persist the audiobook row first.
        TimelineIngestionService.persistAudiobook(
            db: db, folderURL: folder, tracks: [], duration: nil)
        let didImport = await TextAutoImportScanner.importTextFile(
            textURL: file, audiobookID: id, databaseService: db, force: false)

        #expect(didImport)
        // Chapter 0 holds body content narration reads (front matter excluded).
        let chapterZero = try EPubBlockDAO(db: db.writer).blocks(for: id, chapterIndex: 0)
        #expect(chapterZero.count > 0)
        #expect(chapterZero.allSatisfy { !$0.isFrontMatter })
        // Two chapters total.
        let allBlocks = try EPubBlockDAO(db: db.writer).blocks(for: id)
        #expect(Set(allBlocks.compactMap(\.chapterIndex)) == [0, 1])
        // Inline bold survived into stored textFormats.
        #expect(allBlocks.contains { $0.decodedFormats.contains { $0.type == .bold } })
    }

    @Test func plainTextNoMarkersImportsSingleChapter() async throws {
        let db = try DatabaseService(inMemory: ())
        let (folder, file, id) = try stage(
            "loose.txt", "One paragraph.\n\nAnother paragraph, no chapters at all.")
        defer { try? FileManager.default.removeItem(at: folder) }

        TimelineIngestionService.persistAudiobook(
            db: db, folderURL: folder, tracks: [], duration: nil)
        let didImport = await TextAutoImportScanner.importTextFile(
            textURL: file, audiobookID: id, databaseService: db, force: false)

        #expect(didImport)
        #expect(try EPubBlockDAO(db: db.writer).blocks(for: id, chapterIndex: 0).count > 0)
        let allBlocks = try EPubBlockDAO(db: db.writer).blocks(for: id)
        #expect(Set(allBlocks.compactMap(\.chapterIndex)) == [0])
    }
}
