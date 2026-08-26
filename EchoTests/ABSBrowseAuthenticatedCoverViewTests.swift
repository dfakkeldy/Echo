// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

struct ABSBrowseAuthenticatedCoverViewTests {
    @Test func browseUsesAuthenticatedCoverLoaderInsteadOfTokenURLAsyncImage() throws {
        let source = try Self.source("EchoCore/Views/ABSBrowseView.swift")

        #expect(source.contains("ABSAuthenticatedCoverImage"))
        #expect(source.contains("coverImageData(itemID:"))
        #expect(!source.contains("coverURL(itemID:"))
        #expect(!source.contains("AsyncImage(url: model.makeAudiobookshelfService()?.coverURL"))
    }

    private static func source(_ relativePath: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.deletingLastPathComponent().appending(path: relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
