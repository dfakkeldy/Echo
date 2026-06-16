// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import Echo

final class SafeFileNameTests: XCTestCase {

    func testSanitizesFileURL() {
        let result = SafeFileName.fromAudiobookID("file:///var/mobile/Containers/Shared/AppGroup/books/Great Expectations.m4b")
        XCTAssertFalse(result.contains("file://"))
        XCTAssertFalse(result.contains("//"))
        XCTAssertFalse(result.contains(" "))
        XCTAssertTrue(result.hasPrefix("_var_mobile_Containers_Shared_AppGroup_books"))
    }

    func testReplacesSpecialCharacters() {
        let result = SafeFileName.fromAudiobookID("file:///Users/test:book/file.m4b")
        XCTAssertFalse(result.contains(":"))
        XCTAssertFalse(result.contains("/"))
        XCTAssertTrue(result.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" })
    }

    func testHandlesEmptyInput() {
        let result = SafeFileName.fromAudiobookID("")
        XCTAssertEqual(result, "unknown")
    }

    func testHandlesOnlySpecialChars() {
        // Slashes and colons become underscores, which are valid filename chars
        let result = SafeFileName.fromAudiobookID("///:")
        XCTAssertEqual(result, "____")
    }

    func testTruncatesLongInput() {
        let long = String(repeating: "abcdefghij", count: 50)
        let result = SafeFileName.fromAudiobookID(long)
        XCTAssertLessThanOrEqual(result.count, 128)
    }

    func testPreservesAlphanumericDotsDashes() {
        let result = SafeFileName.fromAudiobookID("my-book_v1.0")
        XCTAssertEqual(result, "my-book_v1.0")
    }

    /// Audiobook IDs are file URLs whose *unique* part (the book folder) comes
    /// last. Two long IDs sharing a 128-scalar prefix must still map to
    /// distinct names, or their caches and image assets collide on disk.
    func testLongIDsDifferingOnlyInTruncatedTailStayDistinct() {
        let sharedPrefix = "file:///Users/test/Library/Mobile Documents/com~apple~CloudDocs/"
            + String(repeating: "Audiobooks/", count: 12)
        let bookA = SafeFileName.fromAudiobookID(sharedPrefix + "Author/Book One/")
        let bookB = SafeFileName.fromAudiobookID(sharedPrefix + "Author/Book Two/")

        XCTAssertNotEqual(bookA, bookB)
        XCTAssertLessThanOrEqual(bookA.count, 128)
        XCTAssertLessThanOrEqual(bookB.count, 128)
    }

    /// The long-ID mapping must be stable across calls and launches (no
    /// process-seeded hashing) — derived cache paths are recomputed later.
    func testLongIDMappingIsDeterministic() {
        let long = "file:///" + String(repeating: "deep/path/", count: 30) + "Book/"
        XCTAssertEqual(SafeFileName.fromAudiobookID(long), SafeFileName.fromAudiobookID(long))
    }
}
