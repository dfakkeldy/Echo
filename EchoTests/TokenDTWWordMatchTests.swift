// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct TokenDTWWordMatchTests {
    @Test func emitsPerTokenMatchesWithAudioTimes() {
        let epub = [
            TokenDTW.EPubToken(text: "hello", blockID: "b0"),
            TokenDTW.EPubToken(text: "world", blockID: "b0"),
        ]
        let audio = [
            TokenDTW.AudioToken(text: "hello", time: 1.0),
            TokenDTW.AudioToken(text: "world", time: 1.6),
        ]
        let matches = TokenDTW.wordMatches(epub: epub, audio: audio)
        #expect(matches.count == 2)
        #expect(matches[0].blockID == "b0" && matches[0].wordIndexInBlock == 0)
        #expect(abs(matches[0].audioTime - 1.0) < 0.001)
        #expect(matches[1].wordIndexInBlock == 1)
        #expect(abs(matches[1].audioTime - 1.6) < 0.001)
        #expect(matches.allSatisfy { $0.runLength >= 1 })
    }
}
