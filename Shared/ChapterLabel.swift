// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One answer to "what is the current chapter called", shared by every player
/// headline (iPhone, mini player, Watch, Mac) and the reader header. The
/// chapter number lives in the progress caption ("Chapter 1 of 20 · 1% of
/// book"), so headlines carry the name alone: a narrated title
/// ("ch. 1: A Sad Part") and an authored heading ("1. A Sad Part") both read
/// "A Sad Part". Chapter lists keep their stored titles, where the number
/// helps orientation.
enum ChapterLabel {
    /// "Chapter 3" for zero-based index 2: the label of an untitled chapter.
    nonisolated static func fallback(index: Int) -> String {
        String(localized: "Chapter \(index + 1)")
    }

    /// A chapter title without its leading chapter number. A "Part N" label
    /// is structure, not a number prefix, so it is kept whole. A bare number
    /// counts as a prefix only when punctuation follows it ("1. A Sad Part");
    /// "24 Hours in Paris" keeps its number because it is part of the name.
    nonisolated static func name(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        let lowered = trimmed.lowercased()
        guard !lowered.hasPrefix("part"), !lowered.hasPrefix("pt") else { return title }
        let afterDigits = trimmed.drop(while: \.isNumber)
        if afterDigits.count < trimmed.count,
            let next = afterDigits.first(where: { !$0.isWhitespace }),
            !".:-_)–—".contains(next)
        {
            return title
        }
        return title.strippingTrackNumberPrefix()
    }

    /// The player headline: the current chapter's name in a chaptered book,
    /// otherwise the track title.
    nonisolated static func headline(
        chapterCount: Int,
        chapterTitle: String,
        chapterIndex: Int?,
        trackTitle: String
    ) -> String {
        guard chapterCount >= 2 else { return trackTitle }
        return chapterTitle.isEmpty ? fallback(index: chapterIndex ?? 0) : name(chapterTitle)
    }
}
