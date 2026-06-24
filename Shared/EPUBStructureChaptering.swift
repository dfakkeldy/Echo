// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Derives chapter indices for a book that has **no audio chapter markers** from
/// the book's own EPUB structure, so the reader feed is a real multi-chapter
/// table of contents instead of one undifferentiated "Front Matter" blob.
///
/// Used when an import has an empty audio `chapters` list — whether the book is a
/// standalone EPUB (no audio) or an audiobook whose audio file simply carries no
/// chapter atoms. Prefers the publisher TOC (the shallowest declared depth whose
/// entries repeat); falls back to numbering EPUB spine items. Blocks before the
/// first chapter boundary (front matter) are omitted from the result, so their
/// `chapterIndex` stays `nil`.
///
/// Pure / Foundation-only so iOS, macOS, and the CLI import paths can all share it.
enum EPUBStructureChaptering {
    /// 0-based chapter index per `blockID`. Absent keys mean "no chapter" (front
    /// matter → `chapterIndex` stays `nil`).
    static func chapterIndices(
        blocks: [EPubBlockRecord],
        tocEntries: [EPubTOCEntryRecord]
    ) -> [String: Int] {
        tocChapterIndices(blocks: blocks, tocEntries: tocEntries)
            ?? spineChapterIndices(blocks: blocks)
    }

    /// Chapter by the publisher TOC: a block belongs to the last chapter
    /// boundary at or before it. The chapter level is the shallowest declared
    /// depth whose entries repeat (so a lone "Part I" wrapper doesn't collapse a
    /// multi-chapter book into one chapter); if no depth repeats, the shallowest
    /// depth present. Returns `nil` when the TOC anchors no blocks, so the caller
    /// falls back to spine numbering.
    private static func tocChapterIndices(
        blocks: [EPubBlockRecord],
        tocEntries: [EPubTOCEntryRecord]
    ) -> [String: Int]? {
        guard !tocEntries.isEmpty else { return nil }

        let seqByBlockID = Dictionary(
            blocks.map { ($0.id, $0.sequenceIndex) }, uniquingKeysWith: { first, _ in first })

        // TOC entries resolved to a concrete block, with depth + reading position.
        let anchored: [(depth: Int, seq: Int)] = tocEntries.compactMap { entry in
            guard let blockID = entry.blockID, let seq = seqByBlockID[blockID] else { return nil }
            return (entry.depth, seq)
        }
        guard !anchored.isEmpty else { return nil }

        let countByDepth = Dictionary(grouping: anchored, by: { $0.depth }).mapValues { $0.count }
        let depthsAscending = countByDepth.keys.sorted()
        let chapterDepth =
            depthsAscending.first(where: { countByDepth[$0]! >= 2 }) ?? depthsAscending.first!

        let boundaries = anchored.filter { $0.depth == chapterDepth }.map(\.seq).sorted()
        guard let firstBoundary = boundaries.first else { return nil }

        var result: [String: Int] = [:]
        for block in blocks where block.sequenceIndex >= firstBoundary {
            // Index of the last boundary at or before this block.
            var chapter = 0
            for (i, boundarySeq) in boundaries.enumerated() where boundarySeq <= block.sequenceIndex
            {
                chapter = i
            }
            result[block.id] = chapter
        }
        return result
    }

    /// Fallback chaptering: number EPUB spine items (body matter) 0,1,2…, leaving
    /// front-matter spine items unassigned. Mirrors the long-standing standalone
    /// EPUB import behavior; a degenerate all-front-matter book numbers every
    /// spine so there is still a chapter 0.
    private static func spineChapterIndices(blocks: [EPubBlockRecord]) -> [String: Int] {
        let bodySpines = Set(blocks.filter { !$0.isFrontMatter }.map(\.spineIndex))
        let spinesToNumber = bodySpines.isEmpty ? Set(blocks.map(\.spineIndex)) : bodySpines

        var chapterForSpine: [Int: Int] = [:]
        for spine in spinesToNumber.sorted() { chapterForSpine[spine] = chapterForSpine.count }

        var result: [String: Int] = [:]
        for block in blocks {
            if let chapter = chapterForSpine[block.spineIndex] { result[block.id] = chapter }
        }
        return result
    }
}
