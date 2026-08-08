// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Read-only `resolve-voice-plan` command action shared by the CLI and tests.
nonisolated struct ResolveVoicePlanCommand {
    @MainActor static func run(
        epubURL: URL,
        voicePlanURL: URL,
        writeStandardOutput: (String) -> Void
    ) throws {
        let resolved = try HeadlessNarrationRunner.resolveVoicePlan(
            epubURL: epubURL,
            voicePlanURL: voicePlanURL)
        writeStandardOutput(try HeadlessNarrationRunner.resolveVoicePlanIdentityJSON(resolved))
    }
}
