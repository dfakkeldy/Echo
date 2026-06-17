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

    /// Below the cell budget, the bisection-aware path is identical to the bare
    /// `wordMatches` — it must just delegate.
    @Test func bisectionAwarePathMatchesBareBelowBudget() {
        let epub = [
            TokenDTW.EPubToken(text: "hello", blockID: "b0"),
            TokenDTW.EPubToken(text: "world", blockID: "b0"),
        ]
        let audio = [
            TokenDTW.AudioToken(text: "hello", time: 1.0),
            TokenDTW.AudioToken(text: "world", time: 1.6),
        ]
        let bare = TokenDTW.wordMatches(epub: epub, audio: audio)
        let guarded = TokenDTW.wordMatchesWithBisection(epub: epub, audio: audio)
        #expect(bare == guarded)
    }

    /// A small `maxCells` forces the guarded path to bisect without allocating a
    /// large matrix. It must still recover the strong matches that span the
    /// whole input (the real reason the memory guard exists).
    @Test func bisectionAwarePathStillMatchesWhenForcedToBisect() {
        let tokens = [
            "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf",
            "hotel", "india", "juliet", "kilo", "lima",
        ]
        let epub = tokens.enumerated().map { index, token in
            TokenDTW.EPubToken(text: token, blockID: "b\(index / 3)")
        }
        let audio = tokens.enumerated().map { index, token in
            TokenDTW.AudioToken(text: token, time: Double(index))
        }
        // 12×12 = 144 cells > maxCells of 1 → forced bisection; audio.count ≥ 8.
        let guarded = TokenDTW.wordMatchesWithBisection(
            epub: epub, audio: audio, maxCells: 1, slackBlocks: 1)
        // Every audio time should be recovered for the matching word.
        #expect(guarded.count == tokens.count)
        for match in guarded {
            #expect(match.runLength >= 1)
        }
        // No duplicate (block, wordIndex) survives the overlap merge.
        let keys = guarded.map { "\($0.blockID)#\($0.wordIndexInBlock)" }
        #expect(Set(keys).count == keys.count)
    }
}
