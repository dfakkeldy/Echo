// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct NarrationSpeechRange: Equatable, Sendable {
    let blockID: String
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

struct NarrationSynthesisTiming: Equatable, Sendable {
    let blockID: String
    private(set) var cursor: TimeInterval
    private(set) var speechRanges: [NarrationSpeechRange] = []

    init(blockID: String, blockStart: TimeInterval) {
        self.blockID = blockID
        self.cursor = blockStart
    }

    var blockEnd: TimeInterval { cursor }

    mutating func appendSpeech(text: String, duration: TimeInterval) {
        let end = cursor + duration
        speechRanges.append(
            NarrationSpeechRange(blockID: blockID, text: text, start: cursor, end: end))
        cursor = end
    }

    mutating func appendSilence(duration: TimeInterval) {
        cursor += duration
    }
}
