// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Resolves the display title for each reader chapter, so the iOS and macOS
/// readers name chapters the same way and both prefer what the publisher
/// actually declared.
///
/// The publisher's TOC label wins whenever an entry points at the chapter's
/// first block. It is the only source that carries the whole title: a
/// Calibre-converted chapter file typically opens with the number and the name
/// as two sibling headings (`<h1>2</h1>`, `<h1>COURTROOM 3: …</h1>`), so
/// picking "the chapter's first heading" yields a bare "2", and any chapter
/// starting on a recurring sidebar heading is named after the sidebar. Audio
/// metadata is the fallback, then the caller's own.
///
/// Pure / Foundation-only so every reader surface can share it.
enum ChapterTitleResolver {
    /// Display title per chapter index. Absent keys mean "no better title than
    /// the caller's fallback" — the caller supplies "Chapter N" or a heading.
    ///
    /// - Parameters:
    ///   - firstBlockIDByChapter: each chapter's first block, in reading order.
    ///   - tocEntries: the book's persisted publisher TOC.
    ///   - audioChapterTitles: chapter index → audio metadata title.
    static func titles(
        firstBlockIDByChapter: [Int: String],
        tocEntries: [EPubTOCEntryRecord],
        audioChapterTitles: [Int: String]
    ) -> [Int: String] {
        var tocTitleByBlockID: [String: String] = [:]
        for entry in tocEntries {
            guard let blockID = entry.blockID, tocTitleByBlockID[blockID] == nil else { continue }
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { tocTitleByBlockID[blockID] = title }
        }

        var result: [Int: String] = [:]
        for (chapter, blockID) in firstBlockIDByChapter {
            if let title = tocTitleByBlockID[blockID] { result[chapter] = title }
        }
        for (chapter, rawTitle) in audioChapterTitles where result[chapter] == nil {
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { result[chapter] = title }
        }
        return result
    }
}
