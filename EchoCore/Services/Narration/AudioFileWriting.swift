import Foundation

/// Writes rendered PCM chunks to a single on-disk audio file (AAC).
/// Mocked in tests; the AVFoundation implementation arrives in Plan 3.
protocol AudioFileWriting: Sendable {
    /// Concatenate `chunks` into one file at `url`. Returns total duration written.
    func write(_ chunks: [TTSChunk], to url: URL) async throws -> TimeInterval
}
