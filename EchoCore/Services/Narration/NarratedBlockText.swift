// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The exact source text used to create word-timing rows and validate portable
/// sidecar words. Keeping this policy shared prevents verification from
/// accepting code-cue words that import later rejects against raw source code.
nonisolated enum NarratedBlockText {
    static func text(for block: EPubBlockRecord) -> String? {
        text(
            blockKind: block.blockKind,
            sourceText: block.text,
            narrationText: block.narrationText
        )
    }

    static func text(
        blockKind: String,
        sourceText: String?,
        narrationText: String?
    ) -> String? {
        guard blockKind == EPubBlockRecord.Kind.code.rawValue else {
            return sourceText
        }
        let cue = narrationText?.trimmingCharacters(in: .whitespacesAndNewlines)
        return cue?.isEmpty == false ? cue : NarrationCodeBlockCue.fallback
    }
}
