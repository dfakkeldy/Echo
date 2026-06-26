// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import Synchronization

/// Reads a window of an audio file and converts it to 16 kHz mono Float32 —
/// WhisperKit's expected input format.
///
/// Reads directly from the file on a background queue, so it never touches
/// the playback graph: no taps, no time-pitch distortion at non-1× playback
/// speeds, and no real-time-thread constraints.
// `nonisolated`: pure off-main file I/O (it runs on a global dispatch queue). Under
// the iOS target's Swift 6 MainActor default isolation it would otherwise be
// inferred `@MainActor`, which would make the local `AVAudioPCMBuffer` main-actor-
// isolated and unable to cross into the converter feed `Mutex`. Callers `await`.
nonisolated enum AudioSegmentReader {
    static let sampleRate: Double = 16_000

    /// - Returns: 16 kHz mono samples for `[time, time + duration]`, clipped
    ///   to the file's length. Empty when `time` is past the end.
    static func samples(
        from fileURL: URL,
        at time: TimeInterval,
        duration: TimeInterval
    ) async throws -> [Float] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let file = try AVAudioFile(forReading: fileURL)
                    let fileFormat = file.processingFormat
                    let fileSampleRate = fileFormat.sampleRate

                    let startFrame = AVAudioFramePosition(max(0, time) * fileSampleRate)
                    let frameCount = AVAudioFrameCount(duration * fileSampleRate)
                    let totalFrames = file.length

                    guard startFrame < totalFrames else {
                        continuation.resume(returning: [])
                        return
                    }
                    let actualFrames = min(frameCount, AVAudioFrameCount(totalFrames - startFrame))
                    file.framePosition = startFrame

                    guard
                        let buffer = AVAudioPCMBuffer(
                            pcmFormat: fileFormat, frameCapacity: actualFrames
                        )
                    else {
                        continuation.resume(throwing: AutoAlignmentError.captureFailed)
                        return
                    }
                    try file.read(into: buffer)

                    guard
                        let floatData = convertTo16kHzMono(
                            buffer: buffer, sourceFormat: fileFormat
                        )
                    else {
                        continuation.resume(throwing: AutoAlignmentError.captureFailed)
                        return
                    }
                    continuation.resume(returning: floatData)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Converts an audio buffer to 16 kHz mono Float32 samples.
    ///
    /// `sending buffer`: the caller hands the freshly-read buffer over exclusively,
    /// which lets it flow into the converter-feed `Mutex` below without a data race.
    private static func convertTo16kHzMono(
        buffer: sending AVAudioPCMBuffer,
        sourceFormat: AVAudioFormat
    ) -> [Float]? {
        guard
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            )
        else { return nil }

        // If the source already matches, copy directly.
        if sourceFormat.sampleRate == sampleRate,
            sourceFormat.channelCount == 1,
            sourceFormat.commonFormat == .pcmFormatFloat32
        {
            guard let channelData = buffer.floatChannelData else { return nil }
            let count = Int(buffer.frameLength)
            return Array(UnsafeBufferPointer(start: channelData[0], count: count))
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            return nil
        }

        let inputFrames = buffer.frameLength
        let outputFrames = AVAudioFrameCount(
            Double(inputFrames) * (sampleRate / sourceFormat.sampleRate)
        )
        guard
            let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat, frameCapacity: outputFrames
            )
        else { return nil }

        // `AVAudioConverterInputBlock` is a `@Sendable` typealias, so under Swift 6
        // it cannot capture a mutable `var` or a non-Sendable `AVAudioPCMBuffer`
        // directly. The block is in fact invoked synchronously by `convert(...)` on
        // this thread, but we satisfy the type system honestly (no `@unchecked`/
        // `nonisolated(unsafe)`) by holding the one-shot feed state behind a `Mutex`,
        // which is `Sendable`. The block supplies the source buffer exactly once:
        // AVAudioConverter pulls input repeatedly for sample-rate conversion, and
        // re-returning the already-consumed buffer would re-feed stale samples (§5.5).
        let feedState = Mutex<AVAudioPCMBuffer?>(buffer)
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            feedState.withLock { pending in
                guard let next = pending else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                pending = nil
                outStatus.pointee = .haveData
                return next
            }
        }

        var conversionError: NSError?
        let status = converter.convert(
            to: outputBuffer, error: &conversionError, withInputFrom: inputBlock)
        if status == .error || conversionError != nil {
            return nil
        }

        guard let channelData = outputBuffer.floatChannelData else { return nil }
        let count = Int(outputBuffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: count))
    }
}
