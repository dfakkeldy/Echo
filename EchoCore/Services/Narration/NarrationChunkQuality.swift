// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated enum NarrationChunkQuality: Equatable, Sendable {
    enum RejectionReason: Equatable, Sendable {
        case emptyAudio
        case nearSilentAudio
        case implausibleDuration
    }

    case acceptable
    case rejected(RejectionReason)

    static func evaluate(_ chunk: TTSChunk, text: String) -> NarrationChunkQuality {
        let hasSpeakableText = text.contains { $0.isLetter || $0.isNumber }
        guard hasSpeakableText else { return .acceptable }
        guard !chunk.samples.isEmpty, chunk.duration > 0 else { return .rejected(.emptyAudio) }

        let meanSquare = chunk.samples.reduce(Float.zero) { partial, sample in
            partial + sample * sample
        } / Float(chunk.samples.count)
        let rms = sqrt(meanSquare)
        guard rms > 0.000_01 else { return .rejected(.nearSilentAudio) }

        let wordCount = max(1, text.split(whereSeparator: \.isWhitespace).count)
        let minimumReasonableDuration = min(0.25, Double(wordCount) * 0.05)
        guard chunk.duration >= minimumReasonableDuration else {
            return .rejected(.implausibleDuration)
        }
        return .acceptable
    }
}
