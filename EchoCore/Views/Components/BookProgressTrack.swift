// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Pure math for the book-progress hairline (audit B5): chapter-boundary tick
/// fractions and the caption string, separated from the Canvas for testing.
enum BookProgressTrackModel {
    /// Fractions in (0, 1) of total book duration where interior chapter
    /// boundaries fall. Chapter 0's start (= 0) is skipped.
    static func tickFractions(chapters: [Chapter], totalDuration: Double) -> [Double] {
        guard totalDuration > 0 else { return [] }
        return chapters.dropFirst().compactMap { chapter in
            let fraction = chapter.startSeconds / totalDuration
            return (fraction > 0 && fraction < 1) ? fraction : nil
        }
    }

    /// "Chapter 1 of 20 · 1% of book". The headline above carries the
    /// chapter's name, so the caption carries its number.
    static func caption(bookFraction: Double, chapterIndex: Int?, chapterCount: Int) -> String {
        let pct = Int((bookFraction * 100).rounded())
        guard chapterCount > 1, let chapterIndex, (0..<chapterCount).contains(chapterIndex) else {
            return String(localized: "\(pct)% of book")
        }
        return String(localized: "Chapter \(chapterIndex + 1) of \(chapterCount) · \(pct)% of book")
    }

    static func caption(bookFraction: Double, detail: String?) -> String {
        let pct = Int((bookFraction * 100).rounded())
        guard let detail, !detail.isEmpty else {
            return String(localized: "\(pct)% of book")
        }
        return String(localized: "\(detail) · \(pct)% of book")
    }
}

/// The 3pt hairline book track under the chapter scrubber: the ring around
/// play carries ambient total progress; this track adds what the ring can't —
/// chapter ticks on the same time axis as the scrubber.
struct BookProgressTrack: View {
    let bookFraction: Double
    let tickFractions: [Double]
    let accent: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(accent.opacity(0.55))
                    .frame(width: max(0, geo.size.width * min(max(bookFraction, 0), 1)))
                Canvas { context, size in
                    for fraction in tickFractions {
                        let x = size.width * fraction
                        var path = Path()
                        path.move(to: CGPoint(x: x, y: -1))
                        path.addLine(to: CGPoint(x: x, y: size.height + 1))
                        context.stroke(path, with: .color(.primary.opacity(0.25)), lineWidth: 1)
                    }
                }
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)  // the caption below carries the same info
    }
}
