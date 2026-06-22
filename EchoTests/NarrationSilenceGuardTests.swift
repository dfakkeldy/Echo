// SPDX-License-Identifier: GPL-3.0-or-later
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

    @Test func doesNotSplitShortOrSpacelessText() {
        #expect(NarrationSilenceGuard.splitForRetry("hi", minLength: 16) == nil)
        #expect(NarrationSilenceGuard.splitForRetry("supercalifragilistic", minLength: 16) == nil)
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
}
