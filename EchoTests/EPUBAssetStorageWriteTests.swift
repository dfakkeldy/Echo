// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct EPUBAssetStorageWriteTests {
    @Test func writesImageDataAndReturnsLoadablePath() throws {
        let db = try DatabaseService(inMemory: ())
        let storage = EPUBAssetStorage(databaseService: db)
        defer { try? storage.removeAll(for: "book-A") }
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47])  // "\x89PNG" — enough for a file write
        let path = try #require(
            storage.writeImageData(pngBytes, audiobookID: "book-A", filename: "fig-0.png"))
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == pngBytes)
    }
}
