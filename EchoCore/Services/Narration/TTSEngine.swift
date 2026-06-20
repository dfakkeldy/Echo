// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Identifier for a narration voice (e.g. a Kokoro voicepack key).
struct VoiceID: RawRepresentable, Hashable, Sendable, Codable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }
}

/// A rendered span of speech audio for one block of text.
/// Samples are mono Float PCM at `sampleRate`. `Sendable` so it can cross
/// the actor→main boundary safely (no non-Sendable AVAudioPCMBuffer).
struct TTSChunk: Sendable, Equatable {
    let samples: [Float]
    let sampleRate: Double
    let duration: TimeInterval

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
}

/// One step of the engine's one-time `prepare()` — surfaced so the UI can show
/// real progress instead of sitting on "Narrating chapter 1" while the model set
/// downloads and the CoreML graphs compile.
enum NarrationPrepareProgress: Sendable, Equatable {
    case downloadingModels(fraction: Double)  // 0…1
    case compilingModels(done: Int, total: Int)
    case ready
}

extension TTSEngine {
    /// Default implementation of the `prepare(progress:)` requirement: ignore the
    /// callback and run the plain `prepare()`. The real engine (`OnnxKokoroEngine`)
    /// overrides it to report download/load progress; `MockTTSEngine` inherits this
    /// no-op.
    func prepare(
        progress: @escaping @Sendable (NarrationPrepareProgress) -> Void
    ) async throws {
        try await prepare()
    }
}

/// Pure mapping from a prepare step to the macOS batch item's (fraction, message).
/// Prepare occupies the item's first 0→0.15 band so the bar stays monotonic with
/// the chapter loop (rebased to 0.15 + 0.80·n/count). Download fills 0→0.075,
/// compile fills 0.075→0.15; the detail text carries the real granularity.
enum NarrationPrepareStatus {
    static func batch(for progress: NarrationPrepareProgress) -> (fraction: Double, message: String)
    {
        switch progress {
        case .downloadingModels(let f):
            let c = min(max(f, 0), 1)
            return (0.075 * c, "Preparing voice models (one-time, ~850 MB)… \(Int(c * 100))%")
        case .compilingModels(let done, let total):
            // "Loading" not "Compiling": after the first run every model is a fast
            // cache-load (the compile is persisted), yet this callback still fires
            // per model — "Compiling" on a sub-second load would be misleading.
            let frac = total > 0 ? Double(done) / Double(total) : 0
            return (0.075 + 0.075 * frac, "Loading voice models… \(done) of \(total)")
        case .ready:
            return (0.15, "Voice models ready")
        }
    }
}
