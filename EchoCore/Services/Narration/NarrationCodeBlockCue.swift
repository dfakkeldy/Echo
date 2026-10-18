// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Spoken-audio policy for `.code` blocks: narration speaks a short cue (the
/// import-time caption in `narrationText`, else a generic fallback) and never
/// the code itself. The helper is shared by synthesis, QA, and sidecar
/// verification so each surface applies the same cue/fallback policy.
nonisolated enum NarrationCodeBlockCue {
    static let fallback = "Code listing."

    /// The exact string narration should synthesize for `block`, or nil when
    /// the block is not a code block (normal pipeline applies).
    static func spokenText(for block: EPubBlockRecord) -> String? {
        guard EPubBlockRecord.Kind(rawValue: block.blockKind) == .code else { return nil }
        let cue = block.narrationText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cue, !cue.isEmpty { return cue }
        return fallback
    }
}
