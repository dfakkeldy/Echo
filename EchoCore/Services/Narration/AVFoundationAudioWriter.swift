// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation

/// Writes PCM samples into an M4A (Apple Lossless / ALAC) file. Both the batch
/// `write` and the incremental `makeStream` paths share one `ALACFileStream`
/// actor, so the non-Sendable `AVAudioFile` and the encode work stay off the
/// caller's actor — a chapter's worth of encoding never blocks the main thread.
///
/// We use ALAC (lossless) rather than 64 kbps AAC: the lossy encoder introduced a
/// constant high-pitched whine into the rendered narration cache. ALAC lives in
/// the same MPEG-4 (.m4a) container, so the cache filename/extension is unchanged
/// — no ripple into resume or read-along parsing. This is also the diagnostic: if
/// the whine survives a lossless round-trip, it lives in the raw Kokoro vocoder
/// output, not the encoder.
struct AVFoundationAudioWriter: AudioFileWriting {

    func write(_ chunks: [TTSChunk], to url: URL) async throws -> TimeInterval {
        guard !chunks.isEmpty else { return 0 }
        // Delegate to the streaming session so batch and incremental share one
        // ALAC encode path. The encode runs on the `ALACFileStream` actor's
        // executor, off the caller's actor — same off-main guarantee as before,
        // now without buffering every chunk first.
        let stream = try makeStream(to: url, sampleRate: chunks.first!.sampleRate)
        for chunk in chunks {
            try await stream.append(chunk)
        }
        return try await stream.finalize()
    }

    func makeStream(to url: URL, sampleRate: Double) throws -> any AudioFileStream {
        try ALACFileStream(url: url, sampleRate: sampleRate)
    }
}

/// Incremental ALAC writer. An `actor` so the non-Sendable `AVAudioFile` is
/// born, used, and closed entirely inside one serialized isolation domain — it
/// never crosses a boundary, and the per-chunk encode stays off the caller's
/// (main) actor. One session = one file; appended chunks are encoded immediately.
///
/// The file is opened lazily on the first non-empty `append`, so a chapter with
/// nothing speakable creates no file (matching the old batch `write([])`) and the
/// file open happens on the actor's executor rather than the caller's thread.
actor ALACFileStream: AudioFileStream {
    private let url: URL
    private let sampleRate: Double
    private let pcmFormat: AVAudioFormat
    private var file: AVAudioFile?
    private var didFinalize = false
    private var totalDuration: TimeInterval = 0

    init(url: URL, sampleRate: Double) throws {
        guard
            let pcmFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1,
                interleaved: false)
        else {
            throw AudioWriterError.formatCreationFailed
        }
        self.url = url
        self.sampleRate = sampleRate
        self.pcmFormat = pcmFormat
    }

    func append(_ chunk: TTSChunk) async throws {
        guard !didFinalize else { throw AudioWriterError.streamFinalized }
        let frameCount = AVAudioFrameCount(chunk.samples.count)
        guard frameCount > 0 else { return }
        let file = try openFileIfNeeded()
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
        try file.write(from: buffer)
        totalDuration += chunk.duration
    }

    func finalize() async throws -> TimeInterval {
        // Dropping the AVAudioFile flushes and closes it deterministically.
        didFinalize = true
        file = nil
        return totalDuration
    }

    private func openFileIfNeeded() throws -> AVAudioFile {
        if let file { return file }
        let outputFormatSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue,
        ]
        let opened = try AVAudioFile(
            forWriting: url, settings: outputFormatSettings,
            commonFormat: .pcmFormatFloat32, interleaved: false)
        file = opened
        return opened
    }
}

enum AudioWriterError: Error {
    case formatCreationFailed
    case bufferCreationFailed
    /// `append` was called after `finalize` closed the session.
    case streamFinalized
}
