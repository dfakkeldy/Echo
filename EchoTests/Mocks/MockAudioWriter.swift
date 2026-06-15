import Foundation

@testable import Echo

/// Records the file it was asked to write and returns Σ chunk durations.
final class MockAudioWriter: AudioFileWriting, @unchecked Sendable {
    private(set) var writtenURLs: [URL] = []
    private(set) var chunkCounts: [Int] = []

    func write(_ chunks: [TTSChunk], to url: URL) async throws -> TimeInterval {
        writtenURLs.append(url)
        chunkCounts.append(chunks.count)
        return chunks.reduce(0) { $0 + $1.duration }
    }
}
