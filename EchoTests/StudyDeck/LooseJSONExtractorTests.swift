// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct LooseJSONExtractorTests {
    @Test func rawObjectPassesThrough() {
        #expect(LooseJSONExtractor.firstJSONObject(in: #"{"cards":[]}"#) == #"{"cards":[]}"#)
    }

    @Test func fencedBlockIsExtracted() {
        let text = "Here are your cards:\n```json\n{\"cards\":[{\"a\":1}]}\n```\nEnjoy!"
        #expect(LooseJSONExtractor.firstJSONObject(in: text) == "{\"cards\":[{\"a\":1}]}")
    }

    @Test func proseWrappedObjectIsExtracted() {
        let text = "Sure! The result is {\"answer\": 42} - let me know if you need more."
        #expect(LooseJSONExtractor.firstJSONObject(in: text) == "{\"answer\": 42}")
    }

    @Test func bracesAndEscapedQuotesInsideStringsDoNotUnbalance() {
        let text = #"{"front":"What does {curly} mean?","back":"A \"brace\"}"}"#
        #expect(LooseJSONExtractor.firstJSONObject(in: text) == text)
    }

    @Test func skipsInvalidCandidateAndFindsLaterObject() {
        let text = "{not json} but then {\"ok\":true} follows"
        #expect(LooseJSONExtractor.firstJSONObject(in: text) == "{\"ok\":true}")
    }

    @Test func returnsNilWhenNoValidObject() {
        #expect(LooseJSONExtractor.firstJSONObject(in: "no json here") == nil)
        #expect(LooseJSONExtractor.firstJSONObject(in: "{\"never\":\"closed\"") == nil)
        #expect(LooseJSONExtractor.firstJSONObject(in: "") == nil)
    }
}
