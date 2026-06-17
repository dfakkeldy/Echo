// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Covers the chapter ordering + titling step of `NarrationExportService.exportM4B`
/// — specifically the >=10 chapter alignment bug, where a lexicographic file sort
/// (ch0, ch1, ch10, ch11, ch2…) silently attached titles to the wrong chapters
/// when titles were looked up by enumerated file position.
@Suite struct NarrationExportOrderingTests {

    private func file(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp").appendingPathComponent(name)
    }

    /// Chapter-cache filenames as `exportChapterFiles` would already have sorted
    /// them: lexicographically, so ch10/ch11 land between ch1 and ch2.
    private func lexicographicFiles(count: Int) -> [URL] {
        (0..<count)
            .map { "book_id-ch\($0)-af_heart-v4.m4a" }
            .sorted()  // mimic exportChapterFiles' lexicographic .sorted()
            .map(file)
    }

    @Test func ordersFilesByNumericChapterIndexNotLexicographically() {
        let files = lexicographicFiles(count: 12)
        let plan = NarrationExportService.orderedChapters(files: files, titlesByChapterIndex: [:])

        let recovered = plan.map {
            NarrationFileNaming.chapterIndex(fromFileName: $0.fileURL.lastPathComponent)
        }
        #expect(recovered == Array(0..<12))
    }

    @Test func attachesTitlesByChapterIndexAcrossDoubleDigitBoundary() {
        // sortOrder == the chapter index the filename embeds.
        let titles = Dictionary(
            uniqueKeysWithValues: (0..<12).map { ($0, "Title \($0)") })
        let plan = NarrationExportService.orderedChapters(
            files: lexicographicFiles(count: 12), titlesByChapterIndex: titles)

        // Each ordered entry's title must match its own chapter index — the bug
        // attached "Title 2" to ch10 etc. once the lexicographic order diverged.
        for entry in plan {
            let index = NarrationFileNaming.chapterIndex(
                fromFileName: entry.fileURL.lastPathComponent)
            #expect(entry.title == "Title \(index!)")
        }
        // Spot-check the exact regression: chapter 10 keeps its own title.
        let ch10 = plan.first {
            NarrationFileNaming.chapterIndex(fromFileName: $0.fileURL.lastPathComponent) == 10
        }
        #expect(ch10?.title == "Title 10")
    }

    @Test func fallsBackToPositionalLabelWhenTitleMissing() {
        // No DB titles → 1-based positional fallback in true chapter order.
        let plan = NarrationExportService.orderedChapters(
            files: lexicographicFiles(count: 3), titlesByChapterIndex: [:])
        #expect(plan.map(\.title) == ["Chapter 1", "Chapter 2", "Chapter 3"])
    }

    @Test func ignoresGapsAndExtraTitleKeys() {
        // Only ch0 and ch5 rendered; titles map also carries an unrelated key.
        let files = [file("book_id-ch5-af_heart-v4.m4a"), file("book_id-ch0-af_heart-v4.m4a")]
        let plan = NarrationExportService.orderedChapters(
            files: files, titlesByChapterIndex: [0: "Prologue", 5: "Finale", 99: "Stray"])
        #expect(plan.map(\.title) == ["Prologue", "Finale"])
    }
}
