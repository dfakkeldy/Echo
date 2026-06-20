// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import Testing

@testable import Echo

@Suite struct AudioExportServiceTests {
    /// Empty input is a clear error, not an empty file.
    @Test func throwsOnNoChapters() async {
        let service = AudioExportService()
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4b")
        await #expect(throws: AudioExportService.ExportError.self) {
            try await service.exportM4B(items: [], outputURL: out)
        }
    }

    #if os(iOS) || os(macOS)
        /// Title metadata written via `session.metadata` survives the
        /// `ChapterMarkerWriter` atom-rewrite pass and is readable back via AVFoundation.
        @Test func embedsTitleMetadataInOutput() async throws {
            let a = try await SilentAudioFixture.makeSilentM4A(seconds: 1)
            let b = try await SilentAudioFixture.makeSilentM4A(seconds: 1)
            defer {
                try? FileManager.default.removeItem(at: a)
                try? FileManager.default.removeItem(at: b)
            }
            let items = [
                ExportItem(title: "One", url: a, timeRange: nil),
                ExportItem(title: "Two", url: b, timeRange: nil),
            ]
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4b")
            defer { try? FileManager.default.removeItem(at: out) }
            try await AudioExportService().exportM4B(
                items: items, outputURL: out,
                metadata: ExportMetadata(title: "Round Trip", author: "Tester", coverArt: nil))

            let meta = try await AVURLAsset(url: out).load(.commonMetadata)
            let titleItem = meta.first { $0.commonKey == .commonKeyTitle }
            #expect((try? await titleItem?.load(.stringValue)) == "Round Trip")
        }
    #endif
}
