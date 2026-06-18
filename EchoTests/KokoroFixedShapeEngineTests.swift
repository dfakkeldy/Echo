// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import Echo

@Suite struct KokoroFixedShapeEngineTests {

    @Test func buildInputsWrapsBosEosAndAlignsAttentionMask() throws {
        // Pure input assembly — no model needed. Validates the G2P → vocab →
        // refS glue produces well-formed KokoroPipeline inputs.
        let inputs = try KokoroFixedShapeEngine.PipelineInputs.make(
            text: "Hi.", voice: VoiceID("af_heart"))
        #expect(inputs.ids.first == 0 && inputs.ids.last == 0) // BOS/EOS
        #expect(inputs.attentionMask.count == inputs.ids.count) // mask aligns
        #expect(inputs.attentionMask.allSatisfy { $0 == 1 }) // no padding pre-bucket
        #expect(inputs.refS.count == 256) // af_heart style row
    }

    @Test func buildInputsRefSClampMatchesPhonemeCount() throws {
        // A very long utterance must not crash refS selection (clamps to row 509).
        let inputs = try KokoroFixedShapeEngine.PipelineInputs.make(
            text: String(repeating: "hello ", count: 500), voice: VoiceID("af_heart"))
        #expect(inputs.refS.count == 256)
    }
}
