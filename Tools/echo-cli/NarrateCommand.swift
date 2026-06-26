// SPDX-License-Identifier: GPL-3.0-or-later
import ArgumentParser
import Foundation

/// `echo-cli narrate` — turn an EPUB into a chaptered .m4b + read-along sidecar.
struct NarrateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "narrate",
        abstract: "Narrate an EPUB or PDF into a chaptered .m4b + alignment sidecar.")

    @Option(help: "EPUB/PDF source file or directory; EPUB folder/entry wins when both are present.")
    var epub: String
    @Option(help: "Output .m4b path.") var out: String
    @Option(help: "Sidecar .alignment.json path (optional).") var sidecar: String?
    @Option(help: "Kokoro voice id.") var voice: String = "af_heart"
    @Option(help: "Book title (m4b metadata).") var title: String
    @Option(help: "Book author (m4b metadata).") var author: String
    @Option(name: .customLong("work-dir"), help: "Intermediates dir (default: next to --out).")
    var workDir: String?
    @Option(name: .customLong("max-chapters"), help: "Chapters per process (default: whole book).")
    var maxChapters: Int?
    @Flag(help: "Continue from existing .anchors markers.") var resume = false

    @MainActor func run() async throws {
        EchoCLI.configureResources()
        let outURL = URL(fileURLWithPath: out)
        let work =
            workDir.map { URL(fileURLWithPath: $0) }
            ?? outURL.deletingLastPathComponent()
            .appendingPathComponent("work-\(outURL.deletingPathExtension().lastPathComponent)")

        // Default is a fresh render; `--resume` continues an interrupted run from
        // its `.anchors-ch<N>.json` markers. Without it, clear prior markers (and
        // their audio) so the book is re-rendered from scratch.
        if !resume {
            let fm = FileManager.default
            let stale =
                (try? fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? []
            for url in stale
            where url.lastPathComponent.hasPrefix(".anchors-ch")
                || url.pathExtension == "m4a"
            {
                try? fm.removeItem(at: url)
            }
        }

        let config = NarrationRunConfig(
            epubURL: URL(fileURLWithPath: epub),
            outM4BURL: outURL,
            sidecarURL: sidecar.map { URL(fileURLWithPath: $0) },
            workDir: work,
            voice: VoiceID(voice),
            title: title,
            author: author,
            maxNewChaptersPerRun: maxChapters)

        let result = try await HeadlessNarrationRunner().run(config) { progress in
            FileHandle.standardError.write(Data("\(progress)\n".utf8))
        }

        if result.complete {
            print(
                "DONE \(result.outM4BURL.path) — \(result.chapters) chapters, "
                    + "\(Int(result.durationSeconds))s")
        } else {
            print("PARTIAL - \(result.capturedThisRun) captured this run out of \(result.chapters) total chapters; re-run to continue")
            throw ExitCode(2)
        }
    }
}
