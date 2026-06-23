// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One audio chapter as a collapsible unit in the unified feed: a header row
/// plus the reader sub-sections (`ch{key}-s{n}`) that belong to it.
struct ReaderChapterGroup: Identifiable, Sendable {
    /// Audio chapter index (`epub_block.chapter_index`); -1 for front matter.
    let chapterKey: Int
    /// Display title for the collapsed header row.
    let title: String
    /// Honest "has aligned audio" flag (from `ChapterAudioStatusResolver`).
    let hasAudio: Bool
    /// The chapter's reader sub-sections, in document order.
    let sections: [ReaderCardSection]

    var id: Int { chapterKey }
}

/// Pure transforms from the per-section feed to the collapsible chapter feed.
/// No UIKit / no DB so a future macOS feed can reuse it.
enum ReaderFeedDisplayBuilder {
    /// Recover the audio chapter key from a section id of the form
    /// `"ch{key}-s{n}"` (e.g. `"ch0-s1"` → 0, `"ch-1-s0"` → -1). Returns `nil`
    /// for non-chapter sections such as `"search"`.
    static func chapterKey(forSectionID id: String) -> Int? {
        guard id.hasPrefix("ch") else { return nil }
        let afterCh = id.dropFirst(2)  // "0-s1" or "-1-s0"
        guard let sRange = afterCh.range(of: "-s") else { return nil }
        return Int(afterCh[afterCh.startIndex..<sRange.lowerBound])
    }

    /// Group sections by chapter key, preserving the order chapters first appear.
    static func groups(
        from sections: [ReaderCardSection], titlesByKey: [Int: String], chaptersWithAudio: Set<Int>
    ) -> [ReaderChapterGroup] {
        var order: [Int] = []
        var byKey: [Int: [ReaderCardSection]] = [:]
        for section in sections {
            guard let key = chapterKey(forSectionID: section.id) else { continue }
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(section)
        }
        return order.map { key in
            let subsections = byKey[key] ?? []
            let rawTitle = titlesByKey[key] ?? subsections.first?.headingStack.first
            let title = (rawTitle?.isEmpty == false) ? rawTitle! : fallbackTitle(forKey: key)
            return ReaderChapterGroup(
                chapterKey: key, title: title, hasAudio: chaptersWithAudio.contains(key),
                sections: subsections)
        }
    }

    /// Diffable-ready sections for the given accordion state. Collapsed chapters
    /// contribute one header-only row; the open chapter contributes all its
    /// sub-sections with the header prepended to the first.
    static func displaySections(groups: [ReaderChapterGroup], openChapterKey: Int?)
        -> [ReaderCardSection]
    {
        var out: [ReaderCardSection] = []
        for group in groups {
            let header = ReaderCardItem.chapterHeader(
                title: group.title, chapterIndex: group.chapterKey)
            if openChapterKey == group.chapterKey {
                for (i, section) in group.sections.enumerated() {
                    let items = (i == 0) ? [header] + section.items : section.items
                    out.append(
                        ReaderCardSection(
                            id: section.id, headingStack: section.headingStack, items: items))
                }
            } else {
                let first = group.sections.first
                out.append(
                    ReaderCardSection(
                        id: first?.id ?? "ch\(group.chapterKey)-s0",
                        headingStack: first?.headingStack ?? [group.title], items: [header]))
            }
        }
        return out
    }

    private static func fallbackTitle(forKey key: Int) -> String {
        key < 0 ? "Front Matter" : "Chapter \(key + 1)"
    }
}
