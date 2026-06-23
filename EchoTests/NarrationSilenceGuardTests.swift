// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// The Kokoro ONNX model sometimes returns a full-length but all-zero waveform
/// for a non-empty input → digital silence in the audiobook. These lock in the
/// guard that detects that and recovers (retry, then re-split) so a real word is
/// never dropped to silence.
@Suite struct NarrationSilenceGuardTests {

    /// Records each `run` call and returns samples from an injected behavior.
    private actor RunStub {
        private(set) var calls: [String] = []
        private let behavior: @Sendable (_ text: String, _ callIndex: Int) -> [Float]
        init(_ behavior: @escaping @Sendable (_ text: String, _ callIndex: Int) -> [Float]) {
            self.behavior = behavior
        }
        func run(_ text: String) -> [Float] {
            let index = calls.count
            calls.append(text)
            return behavior(text, index)
        }
    }

    /// Records the speed of each `run` call and returns samples from an injected
    /// behavior keyed on the speed.
    private actor SpeedRecorder {
        private(set) var speeds: [Float] = []
        private let behavior: @Sendable (_ speed: Float) -> [Float]
        init(_ behavior: @escaping @Sendable (_ speed: Float) -> [Float]) {
            self.behavior = behavior
        }
        func run(_ speed: Float) -> [Float] {
            speeds.append(speed)
            return behavior(speed)
        }
    }

    private static func zeros(_ n: Int = 100) -> [Float] { Array(repeating: 0, count: n) }
    private static func tone(_ n: Int = 100) -> [Float] { Array(repeating: 0.5, count: n) }

    // MARK: - Detection

    @Test func detectsAllZeroAsSilent() {
        #expect(NarrationSilenceGuard.isEffectivelySilent(Self.zeros()))
    }

    @Test func realAudioIsNotSilent() {
        #expect(!NarrationSilenceGuard.isEffectivelySilent(Self.tone()))
    }

    @Test func emptyIsNotSilent() {
        // Empty == "nothing to say" (e.g. an all-punctuation fragment), not the bug.
        #expect(!NarrationSilenceGuard.isEffectivelySilent([]))
    }

    // MARK: - Splitting

    @Test func splitsAtMidpointWordBoundary() {
        let parts = NarrationSilenceGuard.splitForRetry("the quick brown fox", minLength: 16)
        #expect(parts?.0 == "the quick")
        #expect(parts?.1 == "brown fox")
    }

    @Test func prefersAClauseBoundaryOverAnArbitraryMidpointSpace() {
        // When a silent chunk must be split, the two halves are synthesized as
        // separate utterances, so the seam carries sentence-final prosody. Landing
        // it after a comma makes that unavoidable pause sound natural rather than a
        // full stop dropped mid-clause. Here the only comma is left of the midpoint;
        // the guard should still prefer it over the nearer plain space.
        let parts = NarrationSilenceGuard.splitForRetry(
            "alpha beta, gamma delta epsilon zeta", minLength: 16)
        #expect(parts?.0 == "alpha beta,")
        #expect(parts?.1 == "gamma delta epsilon zeta")
    }

    @Test func doesNotSplitShortOrSpacelessText() {
        #expect(NarrationSilenceGuard.splitForRetry("hi", minLength: 16) == nil)
        #expect(NarrationSilenceGuard.splitForRetry("supercalifragilistic", minLength: 16) == nil)
    }

    @Test func doesNotSplitInsideAPronunciationOverrideLink() {
        // A multi-word override `[New York](/ipa/)` contains an interior space that
        // here sits nearest the midpoint. A naive nearest-space split would tear the
        // link apart and corrupt the pronunciation; the guard must skip in-link
        // spaces and split at a real word boundary outside the link.
        let parts = NarrationSilenceGuard.splitForRetry(
            "go to [New York](/nuˈjɔɹk/) now", minLength: 16)
        #expect(parts?.0 == "go to")
        #expect(parts?.1 == "[New York](/nuˈjɔɹk/) now")
    }

    // MARK: - Orchestration

    @Test func returnsAudioOnFirstTry() async throws {
        let stub = RunStub { _, _ in Self.tone() }
        let out = try await NarrationSilenceGuard.synthesize("hello world") { await stub.run($0) }
        #expect(!NarrationSilenceGuard.isEffectivelySilent(out))
        #expect(await stub.calls.count == 1)
    }

    @Test func recoversZeroByPerturbedRetry() async throws {
        // Zero on the first call, real audio on the (perturbed) retry → recovered,
        // no split. The retry text is the same word plus a trailing space.
        let stub = RunStub { _, callIndex in callIndex == 0 ? Self.zeros() : Self.tone() }
        let out = try await NarrationSilenceGuard.synthesize("hello world") { await stub.run($0) }
        #expect(!NarrationSilenceGuard.isEffectivelySilent(out))
        let calls = await stub.calls
        #expect(calls.count == 2)
        #expect(calls[1].trimmingCharacters(in: .whitespaces) == "hello world")  // perturbed, not split
    }

    @Test func recoversShortUnsplittableWordByPerturbing() async throws {
        // A short word with no interior space can't be split — the deterministic
        // engine would reproduce the zero forever. The perturbed retry ("Git ")
        // changes the input so it can recover. This is the gap the perturbation closes.
        let stub = RunStub { text, _ in text == "Git" ? Self.zeros() : Self.tone() }
        let out = try await NarrationSilenceGuard.synthesize("Git") { await stub.run($0) }
        #expect(!NarrationSilenceGuard.isEffectivelySilent(out))
        #expect(await stub.calls.count == 2)
    }

    @Test func recoversLongInputZeroBySplitting() async throws {
        // The full string and its perturbations always zero (length > 18); only a
        // shorter fragment is fine → the guard must split and concatenate the halves.
        let full = "the quick brown fox jumps over"
        let stub = RunStub { text, _ in text.count > 18 ? Self.zeros() : Self.tone() }
        let out = try await NarrationSilenceGuard.synthesize(full) { await stub.run($0) }
        #expect(!NarrationSilenceGuard.isEffectivelySilent(out))
        #expect(out.count == 200)  // two non-silent halves concatenated (perturbation alone → 100)
        #expect(await stub.calls.contains { $0.count <= 18 })  // it actually split
    }

    @Test func terminatesWhenAlwaysSilentAndUnsplittable() async throws {
        // Pathological: every call is silent and the text can't be split. Must
        // return (silent) in bounded calls, never loop forever.
        let stub = RunStub { _, _ in Self.zeros() }
        let out = try await NarrationSilenceGuard.synthesize("hi", maxRetries: 2) {
            await stub.run($0)
        }
        #expect(NarrationSilenceGuard.isEffectivelySilent(out))
        #expect(await stub.calls.count == 3)  // initial + 2 retries, then give up
    }

    // MARK: - Speed nudge

    @Test func speedNudgeStaysOnNormalSpeedWhenAudible() async throws {
        // The common case (~90% of chunks): audio at the first/normal speed, so no
        // nudge — zero extra synthesis for chunks that come back fine.
        let rec = SpeedRecorder { _ in Self.tone() }
        let out = try await NarrationSilenceGuard.synthesizeWithSpeedNudge(
            speeds: [1.0, 1.03, 0.97]) { await rec.run($0) }
        #expect(!NarrationSilenceGuard.isEffectivelySilent(out))
        #expect(await rec.speeds == [1.0])
    }

    @Test func speedNudgeRecoversAtFirstNonSilentSpeed() async throws {
        // Silent at 1.0, recovers at the first nudge → ONE utterance, no split, so
        // no audible seam. Stops as soon as it recovers (doesn't try 0.97).
        let rec = SpeedRecorder { speed in speed == 1.0 ? Self.zeros() : Self.tone() }
        let out = try await NarrationSilenceGuard.synthesizeWithSpeedNudge(
            speeds: [1.0, 1.03, 0.97]) { await rec.run($0) }
        #expect(!NarrationSilenceGuard.isEffectivelySilent(out))
        #expect(await rec.speeds == [1.0, 1.03])
    }

    @Test func speedNudgeReturnsSilentAfterTryingEverySpeed() async throws {
        // Speed alone can't recover it → returns silent so the caller escalates to
        // the text perturb/split ladder. Each speed is tried exactly once.
        let rec = SpeedRecorder { _ in Self.zeros() }
        let out = try await NarrationSilenceGuard.synthesizeWithSpeedNudge(
            speeds: [1.0, 1.03, 0.97]) { await rec.run($0) }
        #expect(NarrationSilenceGuard.isEffectivelySilent(out))
        #expect(await rec.speeds == [1.0, 1.03, 0.97])
    }
}
