// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct KokoroFixedShapeEngineTests {

    @Test func buildInputsWrapsBosEosAndAlignsAttentionMask() throws {
        // Pure input assembly — no model needed. Validates the G2P → vocab →
        // refS glue produces well-formed KokoroPipeline inputs.
        let inputs = try KokoroFixedShapeEngine.PipelineInputs.make(
            text: "Hi.", voice: VoiceID("af_heart"))
        #expect(inputs.ids.first == 0 && inputs.ids.last == 0)  // BOS/EOS
        #expect(inputs.attentionMask.count == inputs.ids.count)  // mask aligns
        #expect(inputs.attentionMask.allSatisfy { $0 == 1 })  // no padding pre-bucket
        #expect(inputs.refS.count == 256)  // af_heart style row
    }

    @Test func buildInputsRefSClampMatchesPhonemeCount() throws {
        // A very long utterance must not crash refS selection (clamps to row 509).
        let inputs = try KokoroFixedShapeEngine.PipelineInputs.make(
            text: String(repeating: "hello ", count: 500), voice: VoiceID("af_heart"))
        #expect(inputs.refS.count == 256)
    }

    // MARK: - splitToFit (token-aware over-cap re-split; tokenizer injected)

    @Test func splitToFitPassesThroughTextUnderCap() {
        // Already within budget → returned whole, no splitting.
        let pieces = KokoroFixedShapeEngine.splitToFit(
            "Hello there friend.", maxTokens: 256, tokenCount: { $0.count })
        #expect(pieces == ["Hello there friend."])
    }

    @Test func splitToFitBoundsEveryDivisiblePieceToCap() {
        // ~1 token/char tokenizer; cap 50. A long multi-word string must split into
        // pieces each ≤ cap, and every word must survive (no content dropped).
        let text = String(repeating: "alpha beta gamma delta ", count: 20)  // ~460 chars
        let pieces = KokoroFixedShapeEngine.splitToFit(
            text, maxTokens: 50, tokenCount: { $0.count })
        #expect(pieces.allSatisfy { $0.count <= 50 })  // every leaf within budget
        let wordsIn = text.split(separator: " ").count
        let wordsOut = pieces.flatMap { $0.split(separator: " ") }.count
        #expect(wordsOut == wordsIn)  // lossless
    }

    @Test func splitToFitReturnsIndivisibleFragmentAsIsAndTerminates() {
        // A single token that the tokenizer always reports as over-cap must not loop;
        // it is returned as-is for the caller to skip.
        let pieces = KokoroFixedShapeEngine.splitToFit(
            "supercalifragilisticexpialidocious", maxTokens: 5, tokenCount: { _ in 9999 })
        #expect(pieces == ["supercalifragilisticexpialidocious"])
    }

    @Test func splitToFitTerminatesOnPathologicalSpacelessRun() {
        // A long spaceless run with an always-over-cap tokenizer must still terminate
        // (depth backstop) and not drop the content entirely.
        let pieces = KokoroFixedShapeEngine.splitToFit(
            String(repeating: "x", count: 200), maxTokens: 5, tokenCount: { _ in 9999 })
        #expect(!pieces.isEmpty)
        #expect(pieces.joined().count == 200)  // every character preserved across the split
    }
}
