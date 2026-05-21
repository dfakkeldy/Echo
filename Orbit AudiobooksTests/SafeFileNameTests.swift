import XCTest
@testable import Orbit_Audiobooks

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
}
