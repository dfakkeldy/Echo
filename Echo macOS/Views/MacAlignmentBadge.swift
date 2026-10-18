// SPDX-License-Identifier: GPL-3.0-or-later
//
//  MacAlignmentBadge.swift
//  Echo macOS
//
//  Answers "is this EPUB actually aligned to the audio?" at a glance, in the
//  reader header where the question is asked.
//

import SwiftUI

/// A one-line verdict on how the open book's text relates to its audio.
///
/// The distinction this exists to make is `estimated` versus aligned. Echo
/// gives every imported book a timeline by spreading blocks across each chapter
/// by word count, so the reader scrolls and highlights whether or not a single
/// second of audio has been matched. Before this badge, nothing on macOS
/// separated "the aligner ran and the text follows the narration" from "the
/// reader is guessing" — the two look identical while you're reading.
struct MacAlignmentBadge: View {
    let summary: BookAlignmentSummary

    var body: some View {
        // A book with no reader text has nothing to say about alignment.
        if summary.state != .noText {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
            }
            .font(.caption)
            .foregroundStyle(tint)
            .help(detail)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(detail))
        }
    }

    // MARK: - Presentation

    private var title: String {
        switch summary.state {
        case .aligned: return "Aligned · \(summary.coveragePercent)%"
        case .partial: return "Partly aligned · \(summary.coveragePercent)%"
        case .estimated: return "Estimated only"
        case .unaligned: return "Not aligned"
        case .noText: return ""
        }
    }

    private var symbol: String {
        switch summary.state {
        case .aligned: return "checkmark.seal.fill"
        case .partial: return "circle.lefthalf.filled"
        case .estimated: return "questionmark.circle"
        case .unaligned: return "circle.dashed"
        case .noText: return "circle.dashed"
        }
    }

    private var tint: Color {
        switch summary.state {
        case .aligned: return .green
        case .partial: return .orange
        case .estimated, .unaligned, .noText: return .secondary
        }
    }

    /// The tooltip. Says what the state means in reading terms and, where the
    /// answer is "not really", what would fix it — the badge is only useful if
    /// it tells you whether to trust the highlight you're looking at.
    private var detail: String {
        switch summary.state {
        case .aligned:
            return """
                \(summary.anchoredBlockCount) of \(summary.textBlockCount) paragraphs follow the \
                narration, from \(summary.realAnchorCount) alignment anchors. Read-along and \
                tap-to-seek are accurate here.
                """
        case .partial:
            return """
                Only \(summary.anchoredBlockCount) of \(summary.textBlockCount) paragraphs follow \
                the narration (\(summary.realAnchorCount) anchors). The rest fall back to an \
                estimate, so read-along will drift outside the aligned stretch.
                """
        case .estimated:
            return """
                This book has no alignment anchors. Positions are estimated from word counts, so \
                read-along will drift. Add it to the batch queue to align it against the audio.
                """
        case .unaligned:
            return """
                No audio positions exist for this text yet. Add the book to the batch queue to \
                align it against the audio.
                """
        case .noText:
            return ""
        }
    }
}
