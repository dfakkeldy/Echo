// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import Foundation

    @testable import Echo

    /// Shared test helper that generates a silent `.m4a` fixture via the production
    /// `AVFoundationAudioWriter`. Extracted from `ChapterMarkerWriterTests` so both
    /// chapter-marker and export-service suites can reuse the same helper without
    /// duplication.
    enum SilentAudioFixture {
        private static let sampleRate: Double = 24_000

        /// Renders `seconds` of digital silence to a temp `.m4a` (ALAC) using the
        /// production audio writer. Reliable in the simulator — the same path is
        /// already exercised by `AVFoundationAudioWriterTests`.
        static func makeSilentM4A(seconds: Double) async throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("silent-fixture-\(UUID().uuidString).m4a")
            let chunk = TTSChunk.silence(seconds: seconds, sampleRate: sampleRate)
            _ = try await AVFoundationAudioWriter().write([chunk], to: url)
            return url
        }
    }
#endif
