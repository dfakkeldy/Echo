// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import Foundation
    import Testing

    @testable import Echo

    /// Local regression-corpus harness (design doc Section 6 M5, Section 9). Drives the
    /// deterministic narration-QA detector over PUBLIC-DOMAIN fixtures kept
    /// OUT of the repo (no private or copyrighted content is ever committed),
    /// mirroring the out-of-repo gating used by `OnnxKokoroEngineWordTimingTests`
    /// and the headless narration harnesses.
    ///
    /// To run: point `ECHO_REGRESSION_CORPUS_DIR` at a directory of fixture JSON
    /// files (schema below) and run `make test-only FILTER=EchoTests/RegressionCorpusHarnessTests`.
    /// Default: SKIPPED, so the suite stays fast and repo-safe.
    ///
    /// Fixture JSON schema:
    /// { "audiobookID": String,
    ///   "expectedBlocks": [{ "blockID": String, "text": String }],
    ///   "heardWords": [{ "text": String, "start": Double }],
    ///   "expectedWindowCount": Int }
    @Suite struct RegressionCorpusHarnessTests {
        private struct FixtureBlock: Decodable {
            let blockID: String
            let text: String
        }
        private struct FixtureWord: Decodable {
            let text: String
            let start: TimeInterval
        }
        private struct Fixture: Decodable {
            let audiobookID: String
            let expectedBlocks: [FixtureBlock]
            let heardWords: [FixtureWord]
            let expectedWindowCount: Int
        }

        nonisolated private static func resolveCorpusDir() -> URL? {
            ProcessInfo.processInfo.environment["ECHO_REGRESSION_CORPUS_DIR"]
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
        }

        @Test(
            .enabled(
                if: resolveCorpusDir() != nil,
                Comment(
                    rawValue: "set ECHO_REGRESSION_CORPUS_DIR to a public-domain fixture dir to run"
                )))
        func detectorIsStableAcrossCorpus() throws {
            let dir = try #require(Self.resolveCorpusDir())
            let fm = FileManager.default
            let files = try fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            )
            .filter { $0.pathExtension == "json" }
            #expect(!files.isEmpty, "corpus dir had no .json fixtures")

            for file in files {
                let data = try Data(contentsOf: file)
                let fixture = try JSONDecoder().decode(Fixture.self, from: data)
                let expectedBlocks = fixture.expectedBlocks.map {
                    (blockID: $0.blockID, text: $0.text)
                }
                let heardWords = fixture.heardWords.map {
                    TranscribedWord(text: $0.text, start: $0.start)
                }
                let windows = NarrationQADetector.detect(
                    expectedBlocks: expectedBlocks,
                    heardWords: heardWords,
                    audiobookID: fixture.audiobookID)
                #expect(
                    windows.count == fixture.expectedWindowCount,
                    "\(file.lastPathComponent): expected \(fixture.expectedWindowCount) windows, got \(windows.count)"
                )
            }
        }
    }
#endif
