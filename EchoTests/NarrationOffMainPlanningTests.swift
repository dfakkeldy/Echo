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
