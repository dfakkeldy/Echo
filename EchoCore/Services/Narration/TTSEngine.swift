// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Identifier for a narration voice (e.g. a Kokoro voicepack key).
nonisolated struct VoiceID: RawRepresentable, Hashable, Sendable, Codable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }
}

/// One rendered word within a synthesized chunk, timed relative to the chunk's
/// own start. Produced by the Kokoro duration head; `nil` on any engine that
/// can't emit timings (mock) or any failure (so the caller falls back to
/// interpolation). `Sendable` to cross the actor→main boundary inside `TTSChunk`.
nonisolated struct ChunkWordTiming: Sendable, Equatable {
    let wordIndex: Int
    let start: TimeInterval
    let end: TimeInterval
}

/// A rendered span of speech audio for one block of text.
/// Samples are mono Float PCM at `sampleRate`. `Sendable` so it can cross
/// the actor→main boundary safely (no non-Sendable AVAudioPCMBuffer).
nonisolated struct TTSChunk: Sendable, Equatable {
    let samples: [Float]
    let sampleRate: Double
    let duration: TimeInterval
    /// Per-word timing for this chunk (chunk-relative seconds), or `nil` when the
    /// engine can't produce it. Defaulted in the memberwise init so existing
    /// `TTSChunk(samples:sampleRate:duration:)` call sites are unaffected.
    let wordTimings: [ChunkWordTiming]?
    /// OOV words that reached deterministic G2P fallback while producing this
    /// chunk. The render path turns these into non-blocking pronunciation
    /// suggestions; engines that do not phonemize leave it empty.
    let pronunciationFallbackHits: [PronunciationFallbackHit]

    init(
        samples: [Float], sampleRate: Double, duration: TimeInterval,
        wordTimings: [ChunkWordTiming]? = nil,
        pronunciationFallbackHits: [PronunciationFallbackHit] = []
    ) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.duration = duration
        self.wordTimings = wordTimings
        self.pronunciationFallbackHits = pronunciationFallbackHits
    }

    /// A run of digital silence `seconds` long at `sampleRate`. Used for the
    /// chapter lead-out pad so the final word isn't clipped when the player
    /// advances to the next chapter. Frame count is rounded to the nearest
    /// sample so the reported `duration` matches the samples actually written.
    static func silence(seconds: TimeInterval, sampleRate: Double) -> TTSChunk {
        let frameCount = max(0, Int((seconds * sampleRate).rounded()))
        return TTSChunk(
            samples: [Float](repeating: 0, count: frameCount),
            sampleRate: sampleRate,
            duration: Double(frameCount) / sampleRate)
    }
}

/// The swappable narration engine boundary. Mocked in tests; Kokoro in Plan 3.
protocol TTSEngine: Sendable {
    func prepare() async throws
    /// Progress-reporting variant. Declared as a protocol REQUIREMENT (not merely
    /// an extension method) so a call through the `any TTSEngine` existential —
    /// which is how `NarrationService.tts` and the macOS/iOS surfaces invoke it —
    /// dynamically dispatches to a concrete engine's override. An extension-only
    /// method resolves statically to the no-op default below, silently dropping
    /// every progress event. The extension still provides a default, so an engine
    /// that can't report progress (`MockTTSEngine`) need not implement it.
    func prepare(progress: @escaping @Sendable (NarrationPrepareProgress) -> Void) async throws
    func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk
    /// Synthesizes an immutable pronunciation plan. This must be a protocol
    /// requirement so calls through `any TTSEngine` dynamically dispatch to an
    /// engine that consumes the approved phonemes and token IDs directly.
    func synthesize(_ chunk: PlannedSynthesisChunk, voice: VoiceID) async throws -> TTSChunk
    /// Releases model memory. Engines that hold no resident state may keep the
    /// default no-op. Callers may invoke at render-completion boundaries;
    /// prepare()/synthesize must lazily restore whatever unload released.
    func unload() async
}

/// One step of the engine's one-time `prepare()` — surfaced so the UI can show
/// real progress instead of sitting on "Narrating chapter 1" while the ONNX model
/// is delivered and loaded.
nonisolated enum NarrationPrepareProgress: Sendable, Equatable {
    case checkingModel(expectedBytes: Int64)
    case modelCacheHit(byteCount: Int64)
    case downloadingModel(receivedBytes: Int64, totalBytes: Int64)
    case validatingModel(byteCount: Int64)
    case loadingModel
    case ready
}

extension TTSEngine {
    /// Default implementation of the `prepare(progress:)` requirement: run the
    /// plain `prepare()`, then report readiness. The real engine (`OnnxKokoroEngine`)
    /// overrides it to report model-delivery and load progress.
    func prepare(
        progress: @escaping @Sendable (NarrationPrepareProgress) -> Void
    ) async throws {
        try await prepare()
        progress(.ready)
    }

    /// Compatibility path for engines that still accept text. Production Kokoro
    /// overrides this requirement to consume the supplied plan directly.
    func synthesize(_ chunk: PlannedSynthesisChunk, voice: VoiceID) async throws -> TTSChunk {
        try await synthesize(chunk.g2pInputText, voice: voice)
    }

    func unload() async {}
}

/// Pure mapping from a prepare step to the macOS batch item's (fraction, message).
/// Prepare occupies the item's first 0→0.15 band so the bar stays monotonic with
/// the chapter loop (rebased to 0.15 + 0.80·n/count). Model delivery fills
/// 0→0.135 and session load fills 0.135→0.15; detail text carries exact bytes.
enum NarrationPrepareStatus {
    static func batch(for progress: NarrationPrepareProgress) -> (fraction: Double, message: String)
    {
        switch progress {
        case .checkingModel:
            return (0, String(localized: "Checking narration model…"))
        case .modelCacheHit(let byteCount):
            return (
                0.135,
                String(localized: "Narration model cached · \(megabytes(byteCount)) MB")
            )
        case .downloadingModel(let receivedBytes, let totalBytes):
            let fraction = totalBytes > 0
                ? min(max(Double(receivedBytes) / Double(totalBytes), 0), 1)
                : 0
            return (
                0.135 * fraction,
                String(
                    localized:
                        "Downloading narration model… \(Int(fraction * 100))% · \(megabytes(receivedBytes)) of \(megabytes(totalBytes)) MB"
                )
            )
        case .validatingModel(let byteCount):
            return (
                0.135,
                String(localized: "Validating narration model… \(megabytes(byteCount)) MB")
            )
        case .loadingModel:
            return (0.135, String(localized: "Loading narration model…"))
        case .ready:
            return (0.15, String(localized: "Narration model ready"))
        }
    }

    private static func megabytes(_ bytes: Int64) -> Int64 {
        max(0, bytes) / 1_000_000
    }
}
