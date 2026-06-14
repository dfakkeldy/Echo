import AVFoundation
import Foundation

/// Writes PCM samples into an M4A (AAC) file. The encode runs off the caller's
/// actor (via a detached task) so a chapter's worth of AAC encoding never blocks
/// the main thread.
struct AVFoundationAudioWriter: AudioFileWriting {

    func write(_ chunks: [TTSChunk], to url: URL) async throws -> TimeInterval {
        guard !chunks.isEmpty else { return 0 }
        return try await Task.detached(priority: .userInitiated) {
            try AVFoundationAudioWriter.encode(chunks, to: url)
        }.value
    }

    private static func encode(_ chunks: [TTSChunk], to url: URL) throws -> TimeInterval {
        let sampleRate = chunks.first!.sampleRate

        let outputFormatSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64000,
        ]

        let audioFile = try AVAudioFile(
            forWriting: url, settings: outputFormatSettings,
            commonFormat: .pcmFormatFloat32, interleaved: false)

        guard
            let pcmFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1,
                interleaved: false)
        else {
            throw AudioWriterError.formatCreationFailed
        }

        var totalDuration: TimeInterval = 0
        for chunk in chunks {
            let frameCount = AVAudioFrameCount(chunk.samples.count)
            guard frameCount > 0 else { continue }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount)
            else {
                throw AudioWriterError.bufferCreationFailed
            }
            buffer.frameLength = frameCount
            if let channelData = buffer.floatChannelData?[0] {
                chunk.samples.withUnsafeBufferPointer { pointer in
                    channelData.update(from: pointer.baseAddress!, count: Int(frameCount))
                }
            }
            try audioFile.write(from: buffer)
            totalDuration += chunk.duration
        }
        return totalDuration
    }
}

enum AudioWriterError: Error {
    case formatCreationFailed
    case bufferCreationFailed
}
