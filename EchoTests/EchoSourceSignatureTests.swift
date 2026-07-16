// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// `EchoSourceSignature.make(records:)` hashes only the canonical fields that
/// define an EPUB's *content* — portable block id, kind, exact text,
/// front-matter flag, sequence index, and word count — so the signature is
/// stable across devices, imports, and mutable reader state (hidden blocks,
/// local audiobook ids, chapter assignments, asset paths). Every test below
/// pins down one axis of that contract: either "this field must never move
/// the hash" or "this field must always move the hash."
@Suite struct EchoSourceSignatureTests {
    @Test func goldenVectorUsesLengthPrefixedCanonicalFields() {
        let records = [
            makeBlock(
                id: "epub-local-a-s0-b0", kind: "heading", text: "Opening",
                sequenceIndex: 0, isFrontMatter: false, wordCount: 1),
            makeBlock(
                id: "epub-local-a-s0-b1", kind: "paragraph", text: "Exact café text.",
                sequenceIndex: 1, isFrontMatter: false, wordCount: 3),
        ]

        let signature = EchoSourceSignature.make(records: records)

        #expect(signature.algorithm == "echo-canonical-blocks-v1")
        #expect(
            signature.value
                == "sha256:59edb2bf3a7b0ad4bd891c5d015dd3c68af797b63ed6ea726baa99de7f062863")
    }

    @Test func currentAlgorithmMatchesSignatureAlgorithm() {
        #expect(EchoSourceSignature.currentAlgorithm == "echo-canonical-blocks-v1")
    }

    @Test func audiobookIDIsExcludedFromSignature() {
        let localA = [
            makeBlock(
                id: "epub-local-a-s0-b0", kind: "heading", text: "Title",
                sequenceIndex: 0, isFrontMatter: false, wordCount: 1, audiobookID: "local-a")
        ]
        let localB = [
            makeBlock(
                id: "epub-local-b-s0-b0", kind: "heading", text: "Title",
                sequenceIndex: 0, isFrontMatter: false, wordCount: 1, audiobookID: "local-b")
        ]

        #expect(
            EchoSourceSignature.make(records: localA) == EchoSourceSignature.make(records: localB)
        )
    }

    @Test func chapterIndexIsExcludedFromSignature() {
        let chapterZero = [
            makeBlock(
                id: "epub-local-a-s0-b0", kind: "paragraph", text: "Body",
                sequenceIndex: 0, isFrontMatter: false, wordCount: 1, chapterIndex: 0)
        ]
        let chapterSeven = [
            makeBlock(
                id: "epub-local-a-s0-b0", kind: "paragraph", text: "Body",
                sequenceIndex: 0, isFrontMatter: false, wordCount: 1, chapterIndex: 7)
        ]

        #expect(
            EchoSourceSignature.make(records: chapterZero)
                == EchoSourceSignature.make(records: chapterSeven))
    }

    @Test func hiddenStateIsExcludedFromSignature() {
        let visible = [
            makeBlock(
                id: "epub-local-a-s0-b0", kind: "paragraph", text: "Body",
                sequenceIndex: 0, isFrontMatter: false, wordCount: 1, isHidden: false)
        ]
        let hidden = [
            makeBlock(
                id: "epub-local-a-s0-b0", kind: "paragraph", text: "Body",
                sequenceIndex: 0, isFrontMatter: false, wordCount: 1, isHidden: true)
        ]

        #expect(
            EchoSourceSignature.make(records: visible) == EchoSourceSignature.make(records: hidden)
        )
    }

    @Test func imagePathIsExcludedFromSignature() {
        let pathA = [
            makeBlock(
                id: "epub-local-a-s0-b0", kind: "image", text: "Caption",
                sequenceIndex: 0, isFrontMatter: false, wordCount: nil,
                imagePath: "OEBPS/a.png")
        ]
        let pathB = [
            makeBlock(
                id: "epub-local-a-s0-b0", kind: "image", text: "Caption",
                sequenceIndex: 0, isFrontMatter: false, wordCount: nil,
                imagePath: "OEBPS/different/b.png")
        ]

        #expect(
            EchoSourceSignature.make(records: pathA) == EchoSourceSignature.make(records: pathB))
    }

    @Test func inputOrderDoesNotAffectSignature() {
        let ordered = [
            makeBlock(
                id: "epub-local-a-s0-b0", kind: "heading", text: "Opening",
                sequenceIndex: 0, isFrontMatter: false, wordCount: 1),
            makeBlock(
                id: "epub-local-a-s0-b1", kind: "paragraph", text: "Body",
                sequenceIndex: 1, isFrontMatter: false, wordCount: 1),
        ]
        let reversed = Array(ordered.reversed())

        #expect(
            EchoSourceSignature.make(records: ordered) == EchoSourceSignature.make(records: reversed)
        )
    }

    @Test func exactTextChangesSignature() {
        let withPeriod = [
            makeBlock(
                id: "epub-local-a-s0-b0", kind: "paragraph", text: "Exact text.",
                sequenceIndex: 0, isFrontMatter: false, wordCount: 2)
        ]
        let withTrailingSpace = [
            makeBlock(
                id: "epub-local-a-s0-b0", kind: "paragraph", text: "Exact text ",
                sequenceIndex: 0, isFrontMatter: false, wordCount: 2)
        ]

        #expect(
            EchoSourceSignature.make(records: withPeriod)
                != EchoSourceSignature.make(records: withTrailingSpace))
    }

    @Test func isFrontMatterChangesSignature() {
        let body = [
            makeBlock(
                id: "epub-local-a-s0-b0", kind: "paragraph", text: "Preface",
                sequenceIndex: 0, isFrontMatter: false, wordCount: 1)
        ]
        let frontMatter = [
            makeBlock(
                id: "epub-local-a-s0-b0", kind: "paragraph", text: "Preface",
                sequenceIndex: 0, isFrontMatter: true, wordCount: 1)
        ]

        #expect(
            EchoSourceSignature.make(records: body) != EchoSourceSignature.make(records: frontMatter)
        )
    }

    @Test func nullWordCountDiffersFromZero() {
        let nullCount = [
            makeBlock(
                id: "epub-local-a-s0-b0", kind: "paragraph", text: "Body",
                sequenceIndex: 0, isFrontMatter: false, wordCount: nil)
        ]
        let zeroCount = [
            makeBlock(
                id: "epub-local-a-s0-b0", kind: "paragraph", text: "Body",
                sequenceIndex: 0, isFrontMatter: false, wordCount: 0)
        ]

        #expect(
            EchoSourceSignature.make(records: nullCount)
                != EchoSourceSignature.make(records: zeroCount))
    }

    @Test func tiedSequenceIndexBreaksStablyByPortableID() {
        let bBeforeA = [
            makeBlock(
                id: "epub-local-a-s0-b1", kind: "paragraph", text: "Second",
                sequenceIndex: 0, isFrontMatter: false, wordCount: 1),
            makeBlock(
                id: "epub-local-a-s0-b0", kind: "heading", text: "First",
                sequenceIndex: 0, isFrontMatter: false, wordCount: 1),
        ]
        let aBeforeB = [
            makeBlock(
                id: "epub-local-a-s0-b0", kind: "heading", text: "First",
                sequenceIndex: 0, isFrontMatter: false, wordCount: 1),
            makeBlock(
                id: "epub-local-a-s0-b1", kind: "paragraph", text: "Second",
                sequenceIndex: 0, isFrontMatter: false, wordCount: 1),
        ]

        #expect(
            EchoSourceSignature.make(records: bBeforeA)
                == EchoSourceSignature.make(records: aBeforeB))
    }

    private func makeBlock(
        id: String,
        kind: String,
        text: String?,
        sequenceIndex: Int,
        isFrontMatter: Bool,
        wordCount: Int?,
        audiobookID: String = "local-a",
        chapterIndex: Int? = 0,
        isHidden: Bool = false,
        imagePath: String? = nil
    ) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id,
            audiobookID: audiobookID,
            spineHref: "chapter.xhtml",
            spineIndex: 0,
            blockIndex: sequenceIndex,
            sequenceIndex: sequenceIndex,
            blockKind: kind,
            text: text,
            htmlContent: nil,
            cardColor: nil,
            chapterThemeColor: nil,
            imagePath: imagePath,
            chapterIndex: chapterIndex,
            isHidden: isHidden,
            hiddenReason: isHidden ? "user" : nil,
            isFrontMatter: isFrontMatter,
            wordCount: wordCount,
            markers: nil,
            textFormats: nil,
            narrationText: nil,
            createdAt: nil,
            modifiedAt: nil
        )
    }
}
