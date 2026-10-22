// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Accelerate
import Foundation
import os.log

/// Analyzes an audio file to find contiguous periods of silence.
struct SilenceDetectionService {
    let audioURL: URL
    let thresholdRatio: Float = 0.01  // Adjust based on noise floor
    let minimumSilenceDuration: TimeInterval = 2.5

    private let logger = Logger(category: "SilenceDetection")

    struct SilenceGaps {
        let start: TimeInterval
        let end: TimeInterval
        var duration: TimeInterval { end - start }
    }

    /// Returns an array of silence gaps sorted by start time.
    /// Cancellation/channel-energy repair: https://github.com/dfakkeldy/Echo/pull/652
    func detectSilences() async throws -> [SilenceGaps] {
        let worker = Task.detached {
            let file = try AVAudioFile(forReading: self.audioURL)
            let format = file.processingFormat

            // Read in chunks
            let frameCount = AVAudioFrameCount(format.sampleRate * 5.0)  // 5 second chunks
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                throw NSError(
                    domain: "SilenceDetection", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Could not create buffer"])
            }

            var silences: [SilenceGaps] = []
            var isSilent = false
            var silenceStart: TimeInterval = 0

            var currentFrame: AVAudioFramePosition = 0
            let totalFrames = file.length

            while currentFrame < totalFrames {
                try Task.checkCancellation()

                let framesToRead = AVAudioFrameCount(
                    min(AVAudioFramePosition(frameCount), totalFrames - currentFrame))
                file.framePosition = currentFrame
                try file.read(into: buffer, frameCount: framesToRead)

                // A zero-frame read (decode hiccup on a damaged track) would
                // leave currentFrame unchanged and spin the loop forever.
                guard buffer.frameLength > 0 else { break }

                guard let channelData = buffer.floatChannelData else { break }

                // We calculate RMS over small windows (e.g. 0.1s)
                let windowSize = max(1, Int(format.sampleRate * 0.1))
                var offset = 0

                while offset < Int(buffer.frameLength) {
                    let length = min(windowSize, Int(buffer.frameLength) - offset)
                    var rms: Float = 0

                    // A quiet channel must not hide speech on another channel.
                    // Independent energy also handles out-of-phase stereo.
                    for channel in 0..<Int(format.channelCount) {
                        var channelRMS: Float = 0
                        vDSP_rmsqv(
                            channelData[channel].advanced(by: offset), 1, &channelRMS,
                            vDSP_Length(length))
                        rms = max(rms, channelRMS)
                    }

                    let time =
                        TimeInterval(currentFrame + AVAudioFramePosition(offset))
                        / format.sampleRate

                    if rms < self.thresholdRatio {
                        if !isSilent {
                            isSilent = true
                            silenceStart = time
                        }
                    } else {
                        if isSilent {
                            isSilent = false
                            let duration = time - silenceStart
                            if duration >= self.minimumSilenceDuration {
                                silences.append(SilenceGaps(start: silenceStart, end: time))
                            }
                        }
                    }
                    offset += windowSize
                }

                currentFrame += AVAudioFramePosition(buffer.frameLength)
            }

            // Handle trailing silence
            if isSilent {
                let time = TimeInterval(totalFrames) / format.sampleRate
                let duration = time - silenceStart
                if duration >= self.minimumSilenceDuration {
                    silences.append(SilenceGaps(start: silenceStart, end: time))
                }
            }

            return silences
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }
    }
}
