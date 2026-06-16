// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A chapter whose timestamps are cumulative across all M4B books in a multi-file folder.
struct AggregatedChapter: Identifiable, Equatable, Hashable, Sendable {
    var id: String { "\(bookIndex)-\(chapterIndex)" }
    let bookTitle: String
    let bookIndex: Int
    let chapterTitle: String
    let chapterIndex: Int
    let startSeconds: TimeInterval
    let endSeconds: TimeInterval
    let sourceBookURL: URL
}
