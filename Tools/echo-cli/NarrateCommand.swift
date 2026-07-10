// SPDX-License-Identifier: GPL-3.0-or-later
import ArgumentParser
import Foundation

/// `echo-cli narrate` — turn an EPUB into a chaptered .m4b + read-along sidecar.
struct NarrateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "narrate",
        abstract: "Narrate an EPUB or PDF into a chaptered .m4b + alignment sidecar.",
        discussion: """
            Exit codes: 0 = book complete (m4b + sidecar written); 2 = partial \
            batch (re-run with --resume to continue); 1 = any other failure.

            Performance: build with `make echo-cli` (Release). A plain \
            `xcodebuild build -scheme echo-cli` produces a slower Debug (-Onone) \
            binary. The big lever is --jobs: render chapters in parallel — each \
            worker holds its own engine (several hundred MB), so 2–4 is the \
            practical ceiling on a 16 GB machine.
            """)

    @Option(
        help: "EPUB/PDF source file or directory; EPUB folder/entry wins when both are present.")
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
    @Option(name: .customLong("db"), help: "Persistent SQLite database path (default: in-memory).")
    var db: String?
    @Option(help: "Concurrent chapter renders (default 1; 2-4 recommended on 16 GB).")
    var jobs: Int = 1
    @Option(help: "ONNX intra-op threads per engine (default: auto for this machine and --jobs).")
    var threads: Int?
    @Flag(help: "Continue from existing .anchors markers.") var resume = false
    @Flag(
        name: .customLong("no-word-timings"),
        help: "Write block-level anchors only (omit per-word timings from the sidecar).")
    var noWordTimings = false

    @MainActor func run() async throws {
        EchoCLI.configureResources()
        let outURL = URL(fileURLWithPath: out)
        let work =
            workDir.map { URL(fileURLWithPath: $0) }
            ?? outURL.deletingLastPathComponent()
            .appendingPathComponent("work-\(outURL.deletingPathExtension().lastPathComponent)")

        // Default is a fresh render; `--resume` continues an interrupted run from
        // its `.anchors-ch<N>.json` markers. Without it, clear prior markers (and
        // their audio) so the book is re-rendered from scratch — loudly, because
        // an agent retrying a failed run without --resume silently threw away
        // every finished chapter before this warning existed.
        if !resume {
            let fm = FileManager.default
            let stale =
                ((try? fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? [])
                .filter {
                    $0.lastPathComponent.hasPrefix(".anchors-ch") || $0.pathExtension == "m4a"
                }
            if !stale.isEmpty {
                FileHandle.standardError.write(
                    Data(
                        "warning: clearing \(stale.count) prior chapter artifact(s) for a fresh render — pass --resume to continue the previous run instead\n"
                            .utf8))
            }
            for url in stale {
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
            maxNewChaptersPerRun: maxChapters,
            databaseURL: db.map { URL(fileURLWithPath: $0) },
            includeWordTimings: !noWordTimings,
            jobs: max(1, jobs),
            intraOpThreads: threads.map(Int32.init))

        // Overnight renders must survive the Mac idling: without this, the
        // system can sleep mid-book and the wall clock silently balloons.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "echo-cli narrate render")
        defer { ProcessInfo.processInfo.endActivity(activity) }

        let start = Date()
        var lastMessage = ""
        // `progress:` is labeled explicitly — an unlabeled trailing closure
        // would forward-scan-match the runner's `ttsFactory:` parameter.
        let result = try await HeadlessNarrationRunner().run(
            config,
            progress: { progress in
                // Dedupe on the timestamp-free message so unchanged fractions
                // don't spam the log, while real advances keep their elapsed stamp.
                let message = NarrationRunProgressFormatter.message(for: progress)
                guard message != lastMessage else { return }
                lastMessage = message
                let elapsed = Date().timeIntervalSince(start)
                let stamp = NarrationRunProgressFormatter.timestamp(elapsed)
                FileHandle.standardError.write(Data("[\(stamp)] \(message)\n".utf8))
            })

        let wall = Date().timeIntervalSince(start)
        if result.complete {
            let summary = NarrationRunProgressFormatter.summary(
                audioSeconds: result.durationSeconds, wallSeconds: wall)
            print(
                "DONE \(result.outM4BURL.path) — \(result.chapters) chapters, \(summary)")
        } else {
            print(
                "PARTIAL - \(result.capturedThisRun) captured this run out of \(result.chapters) total chapters in \(Int(wall.rounded()))s; re-run with --resume to continue"
            )
            throw ExitCode(2)
        }
    }
}
