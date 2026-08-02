// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

struct NarrationOffMainPlanningTests {
    /// The off-main batch normalizer must produce byte-identical output to
    /// per-block TextNormalizer.normalize — cache signatures depend on it.
    @Test func offMainNormalizationMatchesDirectNormalization() async {
        var blocks: [EPubBlockRecord] = []
        for (i, text) in ["Dr. Smith arrived at 3 p.m.", "Chapter 2nd — costs $1,234.", ""]
            .enumerated()
        {
            blocks.append(block(id: "b\(i)", sequence: i, text: text))
        }
        let result = await NarrationService.normalizeBlocksOffMain(blocks)
        for block in blocks where block.text?.isEmpty == false {
            #expect(result[block.id] == TextNormalizer.normalize(block.text ?? ""))
        }
    }

    /// Empirical executor check, not a trust-the-annotation check. This project
    /// builds with `SWIFT_APPROACHABLE_CONCURRENCY = YES`, which enables
    /// `NonisolatedNonsendingByDefault`: under that mode a plain `nonisolated
    /// async` function runs ON the caller's actor, not off it — only
    /// `@concurrent` actually hops to the cooperative pool. Calling from a
    /// `@MainActor` test and observing `Thread.isMainThread` from inside the
    /// callee's own body (via the debug seam) is what catches a regression
    /// that a "did it type-check" check cannot.
    @Test @MainActor func normalizeBlocksOffMainDoesNotRunOnTheMainThread() async {
        NarrationService.debugNormalizeBlocksRanOnMainThread = nil
        _ = await NarrationService.normalizeBlocksOffMain([
            block(id: "b0", sequence: 0, text: "Hello there.")
        ])
        #expect(NarrationService.debugNormalizeBlocksRanOnMainThread == false)
    }

    /// Same empirical check for the other off-main entry point.
    @Test @MainActor func contentSignatureOffMainDoesNotRunOnTheMainThread() async {
        NarrationService.debugContentSignatureOffMainRanOnMainThread = nil
        _ = await NarrationService.contentSignatureOffMain(
            for: [block(id: "b0", sequence: 0, text: "Hello there.")],
            includeLeadOutPad: true,
            overrides: PronunciationOverrides(entries: [:]),
            occurrenceOverrides: .empty,
            normalizationMode: "deterministic",
            pronunciationPack: .empty)
        #expect(NarrationService.debugContentSignatureOffMainRanOnMainThread == false)
    }

    /// Negative coverage: hidden blocks and code blocks must stay OUT of the
    /// returned map. These two filter clauses (NarrationService.swift's
    /// `normalizeBlocksOffMain`) must stay in lockstep with
    /// `prepareBlocksForRenderPlan`'s own guards, or a block silently gets the
    /// wrong normalized text and its cache signature drifts from what
    /// actually renders.
    @Test func normalizeBlocksOffMainExcludesHiddenAndCodeBlocks() async {
        let visible = block(id: "visible", sequence: 0, text: "Speak this.")
        var hidden = block(id: "hidden", sequence: 1, text: "Do not speak.")
        hidden.isHidden = true
        var code = block(id: "code", sequence: 2, text: "print(1)")
        code.blockKind = EPubBlockRecord.Kind.code.rawValue

        let result = await NarrationService.normalizeBlocksOffMain([visible, hidden, code])

        #expect(result["visible"] != nil)
        #expect(result["hidden"] == nil, "Hidden blocks must not be spoken/normalized.")
        #expect(result["code"] == nil, "Code blocks speak their cue, never normalized prose.")
    }

    /// A block with nil text (e.g. an image block) must be skipped, not crash
    /// or produce a spurious entry.
    @Test func normalizeBlocksOffMainSkipsNilText() async {
        let nilTextBlock = block(id: "nil-text", sequence: 0, text: nil)
        let result = await NarrationService.normalizeBlocksOffMain([nilTextBlock])
        #expect(result.isEmpty)
    }

    /// The binding invariant this whole task rests on: contentSignatureOffMain
    /// must be byte-identical to the direct contentSignature call for the same
    /// inputs, or narration cache identity silently drifts and every cached
    /// chapter re-renders.
    @Test func contentSignatureOffMainMatchesDirectContentSignature() async {
        let blocks = [
            block(id: "b0", sequence: 0, text: "Dr. Smith arrived at 3 p.m."),
            block(id: "b1", sequence: 1, text: "Chapter 2nd — costs $1,234."),
        ]
        let overrides = PronunciationOverrides(entries: [:])
        let occurrenceOverrides = PronunciationOccurrenceOverrides.empty
        let pack = EnglishPronunciationPack.empty

        let direct = NarrationService.contentSignature(
            for: blocks, includeLeadOutPad: true, overrides: overrides,
            occurrenceOverrides: occurrenceOverrides, normalizationMode: "deterministic",
            pronunciationPack: pack)
        let offMain = await NarrationService.contentSignatureOffMain(
            for: blocks, includeLeadOutPad: true, overrides: overrides,
            occurrenceOverrides: occurrenceOverrides, normalizationMode: "deterministic",
            pronunciationPack: pack)

        #expect(direct == offMain)
    }

    private func block(
        id: String,
        sequence: Int,
        text: String?
    ) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id,
            audiobookID: "book",
            spineHref: "chapter.xhtml",
            spineIndex: 0,
            blockIndex: sequence,
            sequenceIndex: sequence,
            blockKind: EPubBlockRecord.Kind.paragraph.rawValue,
            text: text,
            htmlContent: nil,
            cardColor: nil,
            chapterThemeColor: nil,
            imagePath: nil,
            chapterIndex: 0,
            isHidden: false,
            hiddenReason: nil,
            isFrontMatter: false,
            wordCount: nil,
            markers: nil,
            textFormats: nil,
            narrationText: nil,
            createdAt: nil,
            modifiedAt: nil
        )
    }
}
