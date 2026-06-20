// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import Testing

@testable import Echo

/// Covers the chapter ordering + titling step of the audiobook exporter
/// — specifically the >=10 chapter alignment bug, where a lexicographic file sort
/// (ch0, ch1, ch10, ch11, ch2…) silently attached titles to the wrong chapters
/// when titles were looked up by enumerated file position.
@Suite struct NarrationExportOrderingTests {

    private func file(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp").appendingPathComponent(name)
    }

    private func lexicographicFiles(count: Int) -> [URL] {
        (0..<count)
            .map { "book_id-ch\($0)-af_heart-v4.m4a" }
            .sorted()
            .map(file)
    }

    @Test func ordersFilesByNumericChapterIndexNotLexicographically() {
        let files = lexicographicFiles(count: 12)
        let items = NarrationCacheSource.orderedItems(files: files, titlesByChapterIndex: [:])
        let recovered = items.map {
            NarrationFileNaming.chapterIndex(fromFileName: $0.url.lastPathComponent)
        }
        #expect(recovered == Array(0..<12))
    }

    @Test func attachesTitlesByChapterIndexAcrossDoubleDigitBoundary() {
        let titles = Dictionary(uniqueKeysWithValues: (0..<12).map { ($0, "Title \($0)") })
        let items = NarrationCacheSource.orderedItems(
            files: lexicographicFiles(count: 12), titlesByChapterIndex: titles)
        for item in items {
            let index = NarrationFileNaming.chapterIndex(fromFileName: item.url.lastPathComponent)
            #expect(item.title == "Title \(index!)")
        }
        let ch10 = items.first {
            NarrationFileNaming.chapterIndex(fromFileName: $0.url.lastPathComponent) == 10
        }
        #expect(ch10?.title == "Title 10")
    }

    @Test func fallsBackToPositionalLabelWhenTitleMissing() {
        let items = NarrationCacheSource.orderedItems(
            files: lexicographicFiles(count: 3), titlesByChapterIndex: [:])
        #expect(items.map(\.title) == ["Chapter 1", "Chapter 2", "Chapter 3"])
    }

    @Test func ignoresGapsAndExtraTitleKeys() {
        let files = [file("book_id-ch5-af_heart-v4.m4a"), file("book_id-ch0-af_heart-v4.m4a")]
        let items = NarrationCacheSource.orderedItems(
            files: files, titlesByChapterIndex: [0: "Prologue", 5: "Finale", 99: "Stray"])
        #expect(items.map(\.title) == ["Prologue", "Finale"])
    }
}
