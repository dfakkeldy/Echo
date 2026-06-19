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
    /// Progress-reporting prepare. `@escaping` because actor conformers must
    /// capture the closure across a suspension boundary inside a `Task` body —
    /// Swift requires `@escaping` there. Promoting this to a protocol requirement
    /// (rather than a protocol-extension overload) ensures that calls through
    /// `any TTSEngine` use dynamic dispatch and reach the concrete actor's override
    /// instead of always resolving to the extension's static default.
    func prepare(
        progress: @escaping @Sendable (NarrationPrepareProgress) -> Void
    ) async throws
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
    /// Default: no progress. Engines that can report it (KokoroFixedShapeEngine)
    /// override this; FluidAudio + MockTTSEngine inherit the no-op so existing
    /// call sites and test doubles are unaffected.
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
            let frac = total > 0 ? Double(done) / Double(total) : 0
            return (0.075 + 0.075 * frac, "Compiling voice models… \(done) of \(total)")
        case .ready:
            return (0.15, "Voice models ready")
        }
    }
}
