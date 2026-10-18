// SPDX-License-Identifier: GPL-3.0-or-later
import ArgumentParser
import Foundation

/// `echo-cli retag` — re-stamp an existing chaptered `.m4b` with real heading
/// chapter titles, book tags, cover art, and the narration version comment, WITHOUT
/// re-rendering the audio. Used to repair m4bs produced before the export was fixed.
struct RetagCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "retag",
        abstract: "Re-stamp an existing m4b's titles/tags/cover/version comment (no re-render).")

    @Option(help: "The .m4b file to retag.") var m4b: String
    @Option(help: "EPUB directory (expanded) the m4b was narrated from.") var epub: String
    @Option(help: "Output .m4b path (default: retag in place).") var out: String?
    @Option(help: "Book title (m4b metadata).") var title: String
    @Option(help: "Book author (m4b metadata).") var author: String = "Unknown Author"

    @MainActor func run() async throws {
        EchoCLI.configureResources()
        let outURL = URL(fileURLWithPath: out ?? m4b)
        try await M4BRetagger.retag(
            m4b: URL(fileURLWithPath: m4b),
            expandedEPUBDir: URL(fileURLWithPath: epub),
            out: outURL,
            title: title,
            author: author.isEmpty ? nil : author,
            comment: HeadlessNarrationRunner.narrationVersionStamp(),
            replaceExistingBookMetadata: true)
        print("retagged \(outURL.lastPathComponent)")
    }
}
