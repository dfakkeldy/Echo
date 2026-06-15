import Foundation

/// Writes rendered PCM chunks to a single on-disk audio file (ALAC in an .m4a).
/// Mocked in tests; the AVFoundation implementation is `AVFoundationAudioWriter`.
protocol AudioFileWriting: Sendable {
    /// Concatenate `chunks` into one file at `url`. Returns total duration written.
    /// Convenience batch API — delegates to a streaming session under the hood.
    func write(_ chunks: [TTSChunk], to url: URL) async throws -> TimeInterval

    /// Open an incremental ("stream-to-sink") writing session for `url`. Each
    /// appended chunk is encoded straight to disk, so a chapter's peak memory is
    /// one sub-chunk's PCM (~hundreds of KB) instead of a whole chapter's
    /// accumulated `[TTSChunk]` (tens of MB) — the difference that keeps long
    /// narration sessions under the A14 4 GB jetsam ceiling.
    ///
    /// `sampleRate` fixes the output format up front. Synchronous and cheap (it
    /// only opens the file header); the heavy per-chunk encode happens in
    /// `append`, off the caller's actor.
    func makeStream(to url: URL, sampleRate: Double) throws -> any AudioFileStream
}

/// One in-progress incremental write. `Sendable` so the renderer can hold it
/// across `await`s; the concrete AVFoundation session is an `actor`, so its
/// non-`Sendable` `AVAudioFile` stays confined and the encode never blocks the
/// caller's (main) actor.
protocol AudioFileStream: Sendable {
    /// Encode and append one chunk to the open file, advancing total duration by
    /// `chunk.duration`. A zero-sample chunk is a no-op.
    func append(_ chunk: TTSChunk) async throws

    /// Close the file and return the total duration written. After this the
    /// session is spent — further `append` calls throw.
    func finalize() async throws -> TimeInterval
}
