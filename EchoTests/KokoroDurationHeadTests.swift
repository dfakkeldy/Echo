// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import Foundation
    import Testing

    @testable import Echo

    /// Regression guard: the bundled duration head's output must decode through
    /// the ORT ObjC binding.
    ///
    /// The binding's element-type table (`ort_enums.mm`) has no FLOAT16 entry, so
    /// `tensorData()` throws "unsupported tensor element type…" for any fp16
    /// graph output and `tokenDurations` soft-fails — every platform then silently
    /// falls back to interpolated word timings. The head extracted from
    /// `model_fp16.onnx` shipped with a FLOAT16 output (PR #197), so synthesis
    /// word timing never actually ran; `Tools/extract_kokoro_duration_head.py`
    /// now casts the output to fp32. This runs the real bundled model with dummy
    /// inputs (cheap: 28 MB session on the CPU EP, no model download) and fails
    /// if the output ever regresses to a type the binding cannot read.
    struct KokoroDurationHeadTests {
        @Test func bundledDurationHeadOutputDecodesAsPerTokenFloats() throws {
            let url = try #require(
                NarrationResources.url(forResource: "kokoro_dur_head", withExtension: "onnx"),
                "kokoro_dur_head.onnx not bundled")
            let frames = try OnnxKokoroEngine.probeDurationHead(at: url)
            // The probe feeds 4 token ids; the head returns one frame duration
            // per token. A fp16 output never gets here — tensorData() throws.
            #expect(frames.count == 4, "expected one frame duration per token")
            #expect(frames.allSatisfy { $0.isFinite })
        }
    }
#endif
