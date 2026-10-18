// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct ArticleLinkBatchInputParserTests {
    @Test func preservesLineOrderWhileRejectingInvalidAndRepeatedNormalizedLinks() {
        let rows = ArticleLinkBatchInputParser.parse(
            """

              HTTPS://example.com/first#section
            https://example.com/first
            this is not a URL
            https://example.com/second

            """)

        #expect(rows.map(\.lineNumber) == [2, 3, 4, 5])
        #expect(rows.map(\.originalText) == [
            "HTTPS://example.com/first#section",
            "https://example.com/first",
            "this is not a URL",
            "https://example.com/second",
        ])
        #expect(rows.map(\.validation) == [
            .valid(URL(string: "https://example.com/first")!),
            .duplicate(
                URL(string: "https://example.com/first")!,
                firstLineNumber: 2),
            .invalid,
            .valid(URL(string: "https://example.com/second")!),
        ])
    }
}
