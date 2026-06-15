import Foundation

@testable import Echo

/// Records the file it was asked to write and the number of chunks appended per
/// session. Both the batch `write` and the streaming `makeStream` paths funnel
/// through one `MockAudioStream`, so observability is identical regardless of
/// which API the code under test uses.
final class MockAudioWriter: AudioFileWriting, @unchecked Sendable {
    private(set) var writtenURLs: [URL] = []
    private(set) var chunkCounts: [Int] = []

    func write(_ chunks: [TTSChunk], to url: URL) async throws -> TimeInterval {
        let stream = try makeStream(to: url, sampleRate: chunks.first?.sampleRate ?? 24_000)
        for chunk in chunks { try await stream.append(chunk) }
        return try await stream.finalize()
    }

    func makeStream(to url: URL, sampleRate: Double) throws -> any AudioFileStream {
        writtenURLs.append(url)
        return MockAudioStream(writer: self)
    }

    fileprivate func record(chunkCount: Int) { chunkCounts.append(chunkCount) }
}

/// One mock session. Counts appended chunks and sums their durations, reporting
/// the count back to its `MockAudioWriter` on `finalize` so existing assertions
/// (`writer.chunkCounts == [...]`) keep working with the streaming API.
final class MockAudioStream: AudioFileStream, @unchecked Sendable {
    private let writer: MockAudioWriter
    private var count = 0
    private var duration: TimeInterval = 0

    init(writer: MockAudioWriter) { self.writer = writer }

    func append(_ chunk: TTSChunk) async throws {
        count += 1
        duration += chunk.duration
    }

    func finalize() async throws -> TimeInterval {
        writer.record(chunkCount: count)
        return duration
    }
}
