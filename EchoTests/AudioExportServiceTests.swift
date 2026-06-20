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
}
