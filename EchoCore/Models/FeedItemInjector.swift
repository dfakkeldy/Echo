// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Pure positioning: threads note/voice-memo feed items into existing reader
/// sections at their anchor block's document position. No UIKit, no DB — so the
/// macOS target can reuse it later. Mirrors the Phase 2 bookmark/card injection.
enum FeedItemInjector {
    /// Returns new sections with each note/memo inserted immediately after the
    /// `.block` whose id matches its `epubBlockID`. When several items anchor the
    /// same block, notes precede memos, each group ordered as supplied. Items
    /// with no matching block in any section are dropped (not surfaced in-feed).
    static func inject(
        into sections: [ReaderCardSection],
        notesByBlockID: [String: [NoteRecord]],
        memosByBlockID: [String: [VoiceMemoRecord]]
    ) -> [ReaderCardSection] {
        sections.map { section in
            var newItems: [ReaderCardItem] = []
            newItems.reserveCapacity(section.items.count)
            for item in section.items {
                newItems.append(item)
                guard case .block(let block) = item else { continue }
                if let notes = notesByBlockID[block.id] {
                    for note in notes { newItems.append(.note(note)) }
                }
                if let memos = memosByBlockID[block.id] {
                    for memo in memos { newItems.append(.voiceMemo(memo)) }
                }
            }
            return ReaderCardSection(
                id: section.id, headingStack: section.headingStack, items: newItems)
        }
    }
}
