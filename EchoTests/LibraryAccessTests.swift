// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
struct LibraryAccessTests {
    @Test func bookmarkRoundTripsToSameFolder() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lib-access-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let data = try #require(LibraryAccess.makeBookmark(for: tmp))
        let resolved = try #require(LibraryAccess.resolveURL(from: data))
        #expect(resolved.url.standardizedFileURL.path == tmp.standardizedFileURL.path)
    }

    @Test func authorSortNormalizesCommaForm() {
        #expect(LibraryAccess.authorSort("Tolkien, J.R.R.") == "j.r.r. tolkien")
        #expect(LibraryAccess.authorSort("  Frank Herbert ") == "frank herbert")
        #expect(LibraryAccess.authorSort(nil) == nil)
        #expect(LibraryAccess.authorSort("") == nil)
    }
}
