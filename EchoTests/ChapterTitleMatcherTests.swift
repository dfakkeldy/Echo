// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Tier 0 title matching must never produce confident anchors from generic
/// audiobook track labels ("Chapter 1", "Chapter 2", …). Those labels number
/// *tracks*, not book chapters — track 1 is routinely opening credits, so the
/// numbering is shifted relative to the EPUB and carries no alignment signal.
///
/// Regression: The High-Conflict Couple — a 12-track m4b (track 1 = credits)
/// against an 11-chapter EPUB with split chapter-number/chapter-title heading
/// blocks. Tier 0 matched every track title at confidence 1.0 (digit-blind
/// Jaccard), anchored them all to the wrong blocks, and skipped DTW.
struct ChapterTitleMatcherTests {

    // MARK: - Fixtures

    /// The 11 real chapter subtitles from The High-Conflict Couple.
    private static let subtitles = [
        "Understanding Emotion in Relationships",
        "Accepting Yourself and Your Partner",
        "How to Stop Making Things Worse",
        "Being Together When You Are Together",
        "Reactivating Your Relationship",
        "Accurate Expression",
        "Validating Responses: What to Validate and Why",
        "Validating Responses: How to Validate Your Partner",
        "Recovering from Invalidation",
        "Managing Problems and Negotiating Solutions",
        "Transforming Conflict into Closeness",
    ]

    /// Heading blocks shaped like the imported EPUB: front matter, then a
    /// bare chapter-number heading ("Chapter N") followed by a subtitle
    /// heading for each of the 11 chapters, then back matter.
    private func highConflictCoupleHeadings() -> [EPubBlockRecord] {
        var blocks: [EPubBlockRecord] = []
        var seq = 0
        func heading(_ text: String) {
            blocks.append(
                EPubBlockRecord(
                    id: "h\(seq)", audiobookID: "book-1", spineHref: "s\(seq).html",
                    spineIndex: seq, blockIndex: 0, sequenceIndex: seq,
                    blockKind: "heading", text: text,
                    chapterIndex: nil, isHidden: false))
            seq += 1
        }
        heading("Foreword")
        heading("Acknowledgments")
        for (i, subtitle) in Self.subtitles.enumerated() {
            heading("Chapter \(i + 1)")
            heading(subtitle)
        }
        heading("References")
        heading("Biography")
        return blocks
    }

    /// The 12 audiobook tracks: generic labels, track 1 is 3m47s of credits,
    /// so track N actually contains book chapter N−1.
    private func genericTrackChapters() -> [Chapter] {
        let starts: [Double] = [
            0, 227, 2109, 4122, 5379, 7534, 9546,
            12358, 14190, 16706, 18900, 20737,
        ]
        let bookEnd: Double = 22978
        return starts.enumerated().map { i, start in
            Chapter(
                index: i, title: "Chapter \(i + 1)",
                startSeconds: start,
                endSeconds: i + 1 < starts.count ? starts[i + 1] : bookEnd)
        }
    }

    // MARK: - Generic track labels must not match

    @Test func genericTrackTitlesProduceNoMatches() {
        let matches = ChapterTitleMatcher.matchChapterTitles(
            chapters: genericTrackChapters(),
            blocks: highConflictCoupleHeadings()
        )
        #expect(
            matches.isEmpty,
            "Generic 'Chapter N' track labels carry no alignment signal; got \(matches.count) matches"
        )
    }

    // MARK: - Similarity must respect numbers

    @Test func similarityVetoesMismatchedChapterNumbers() {
        // Digit-blind tokenization made these score 1.0 (both → {"chapter"}).
        #expect(ChapterTitleMatcher.similarity(between: "Chapter 2", and: "Chapter 1") < 0.1)
        // A contradicting number is disqualifying even when words overlap.
        #expect(
            ChapterTitleMatcher.similarity(
                between: "Chapter 7: Validating Responses", and: "Chapter 17") < 0.1)
    }

    @Test func similarityToleratesNumberOnOneSideOnly() {
        // Subtitle headings carry no number — the title's number must not veto.
        let confidence = ChapterTitleMatcher.similarity(
            between: "Chapter 3: How to Stop Making Things Worse",
            and: "How to Stop Making Things Worse")
        #expect(confidence >= ChapterTitleMatcher.Threshold.mediumConfidence)
    }

    @Test func matchingNumbersDoNotVeto() {
        let confidence = ChapterTitleMatcher.similarity(
            between: "Chapter 7: Validating Responses: What to Validate and Why",
            and: "Validating Responses: What to Validate and Why")
        #expect(confidence >= ChapterTitleMatcher.Threshold.mediumConfidence)
    }

    // MARK: - Generic track-label detection

    @Test(arguments: [
        "Chapter 1", "Chapter 12", "CHAPTER 7", "chapter 03",
        "Ch. 4", "Chap 9", "Track 03", "Part 2", "Pt. 2",
        "Section 5", "Disc 1", "Book 2", "12", "07", "Chapter IX", "Ch. iv",
    ])
    func recognizesGenericNumericTitles(title: String) {
        #expect(ChapterTitleMatcher.isGenericNumericTitle(title), "'\(title)'")
    }

    @Test(arguments: [
        "Chapter 3: How to Stop Making Things Worse",
        "Understanding Emotion in Relationships",
        "Foreword", "Epilogue", "Acknowledgments",
        "Opening Credits", "Mix",  // bare roman-letter words are real titles
        "1984: A Retrospective",  // number plus real words
        "Chapter Civil", "Part Mild", "Book Mild",  // keyword + roman-letter word
    ])
    func keepsRealTitles(title: String) {
        #expect(!ChapterTitleMatcher.isGenericNumericTitle(title), "'\(title)'")
    }

    // MARK: - Real titles must still match their own headings

    @Test func fullChapterTitlesMatchTheirOwnSubtitleHeadings() throws {
        let chapters = Self.subtitles.enumerated().map { i, subtitle in
            Chapter(
                index: i, title: "Chapter \(i + 1): \(subtitle)",
                startSeconds: Double(i) * 1000,
                endSeconds: Double(i + 1) * 1000)
        }
        let blocks = highConflictCoupleHeadings()
        let matches = ChapterTitleMatcher.matchChapterTitles(
            chapters: chapters, blocks: blocks)

        #expect(matches.count == chapters.count)
        for match in matches {
            let expectedSubtitle = Self.subtitles[match.chapter.index]
            let text = try #require(match.block.text)
            #expect(
                text == expectedSubtitle || text == "Chapter \(match.chapter.index + 1)",
                "chapter \(match.chapter.index) matched '\(text)'")
        }
        // Matched blocks must advance with chapter order — a collapsed or
        // shuffled mapping means the matcher latched onto the wrong headings.
        let sequences = matches.map(\.block.sequenceIndex)
        #expect(sequences == sequences.sorted())
    }

    // MARK: - One block, one match

    @Test func duplicateBestBlockKeepsOnlyBestMatch() {
        // Both titles clear the medium-confidence bar against the single
        // "Foreword" heading; only the stronger (exact) claim may survive.
        let chapters = [
            Chapter(index: 0, title: "Foreword", startSeconds: 0, endSeconds: 100),
            Chapter(index: 1, title: "The Foreword", startSeconds: 100, endSeconds: 200),
        ]
        let blocks = [
            EPubBlockRecord(
                id: "h0", audiobookID: "book-1", spineHref: "s0.html",
                spineIndex: 0, blockIndex: 0, sequenceIndex: 0,
                blockKind: "heading", text: "Foreword",
                chapterIndex: nil, isHidden: false)
        ]
        let matches = ChapterTitleMatcher.matchChapterTitles(
            chapters: chapters, blocks: blocks)

        #expect(
            matches.count <= 1,
            "Two chapters anchored to the same block produce a non-monotonic timeline")
        #expect(matches.first?.chapter.index == 0)
    }
}
