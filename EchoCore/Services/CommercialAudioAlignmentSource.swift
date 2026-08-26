// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Defines which source blocks participate in alignment to commercially
/// narrated audio. Code is displayed from the source document but is not
/// presumed to exist in that separate recording.
nonisolated enum CommercialAudioAlignmentSource {
    static func isEligible(
        blockKind: String,
        text: String?,
        isHidden: Bool
    ) -> Bool {
        guard !isHidden, blockKind != EPubBlockRecord.Kind.code.rawValue else {
            return false
        }
        return text?.isEmpty == false
    }

    static func blocks(from blocks: [EPubBlockRecord]) -> [EPubBlockRecord] {
        blocks.filter {
            isEligible(blockKind: $0.blockKind, text: $0.text, isHidden: $0.isHidden)
        }
    }

    /// Approximate narrated length without letting an unspoken source listing
    /// move every later prose block into the wrong audio chapter.
    static func wordWeight(for block: EPubBlockRecord) -> Int {
        guard block.blockKind != EPubBlockRecord.Kind.code.rawValue else {
            return 0
        }
        return block.wordCount ?? max(1, block.text?.split(separator: " ").count ?? 1)
    }
}
