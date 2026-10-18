// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import Foundation
    import Testing

    @testable import Echo

    /// Narrates a real PDF with the REAL on-device ONNX engine on the simulator.
    /// Heavy (downloads the 163 MB model, renders audio). Gated + fully env-driven
    /// so CI stays green and no absolute paths are committed. Drive it with:
    ///   ECHO_NARRATE_PDF=/path/book.pdf ECHO_NARRATE_WORKDIR=/path/work \
    ///   ECHO_NARRATE_DB=/path/book.sqlite ECHO_NARRATE_OUT=/path/book.m4b \
    ///   ECHO_NARRATE_SIDECAR=/path/book.alignment.json ECHO_NARRATE_MAXCH=5
    /// and re-run until it prints DONE (it renders <=MAXCH chapters per run).
    @MainActor struct PDFNarrationSimIT {
        private nonisolated static var env: [String: String] { ProcessInfo.processInfo.environment }

        @Test(
            .enabled(
                if: PDFNarrationSimIT.env["ECHO_NARRATE_PDF"] != nil,
                "set ECHO_NARRATE_PDF to narrate a PDF on the sim"))
        func narratePDFBatch() async throws {
            let e = Self.env
            let pdf = URL(fileURLWithPath: try #require(e["ECHO_NARRATE_PDF"]))
            let work = URL(fileURLWithPath: e["ECHO_NARRATE_WORKDIR"] ?? NSTemporaryDirectory())
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let config = NarrationRunConfig(
                epubURL: pdf,
                outM4BURL: URL(
                    fileURLWithPath: e["ECHO_NARRATE_OUT"]
                        ?? work.appendingPathComponent("book.m4b").path),
                sidecarURL: e["ECHO_NARRATE_SIDECAR"].map { URL(fileURLWithPath: $0) },
                workDir: work,
                voice: VoiceID(e["ECHO_NARRATE_VOICE"] ?? "af_heart"),
                title: e["ECHO_NARRATE_TITLE"] ?? "Narrated PDF",
                author: e["ECHO_NARRATE_AUTHOR"] ?? "Echo",
                maxNewChaptersPerRun: e["ECHO_NARRATE_MAXCH"].flatMap { Int($0) } ?? 5,
                databaseURL: e["ECHO_NARRATE_DB"].map { URL(fileURLWithPath: $0) })

            // `progress:` labeled explicitly — an unlabeled trailing closure
            // would forward-scan-match the runner's `ttsFactory:` parameter.
            let result = try await HeadlessNarrationRunner().run(
                config,
                progress: { p in
                    FileHandle.standardError.write(Data("\(p)\n".utf8))
                })
            FileHandle.standardError.write(Data("RESULT complete=\(result.complete)\n".utf8))
            // Not an assertion on completeness — partial is expected mid-batch.
            #expect(result.capturedThisRun >= 0)
        }
    }
#endif
