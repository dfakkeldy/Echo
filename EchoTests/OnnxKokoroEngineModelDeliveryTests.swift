// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import Foundation
    import Testing

    @testable import Echo

    /// M5 — the ONNX Kokoro model download must be pinned to an immutable revision and
    /// integrity-checked. A `resolve/main` URL lets a future upstream re-upload
    /// silently swap Echo's ONNX narration model; trusting any file already on
    /// disk lets a truncated/interrupted download be reused forever. These lock in the
    /// pin and the exact-size check that closes both holes.
    @Suite struct OnnxKokoroEngineModelDeliveryTests {

        @Test func modelURLIsPinnedToAnImmutableRevisionNotMain() {
            let url = OnnxKokoroEngine.remoteModelURLForTesting.absoluteString
            // Never the moving branch ref — that's the silent-swap hole.
            #expect(!url.contains("/resolve/main/"))
            // Pinned to the exact commit whose size/hash we validated against.
            #expect(url.contains("/resolve/1939ad2a8e416c0acfeecc08a694d14ef25f2231/"))
        }

        @Test func expectedModelByteCountMatchesThePinnedRevision() {
            // Exact LFS size of onnx/model_fp16.onnx at the pinned commit.
            #expect(OnnxKokoroEngine.expectedModelBytes == 163_234_740)
        }

        @Test func acceptsAFileOfExactlyTheExpectedSize() throws {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("echo-model-ok-\(UUID().uuidString).bin")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try Data(count: 2_048).write(to: tmp)
            #expect(OnnxKokoroEngine.fileHasExpectedSize(at: tmp, expectedBytes: 2_048))
        }

        @Test func rejectsAFileOfTheWrongSize() throws {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("echo-model-bad-\(UUID().uuidString).bin")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try Data(count: 2_047).write(to: tmp)  // one byte short — a truncated download
            #expect(!OnnxKokoroEngine.fileHasExpectedSize(at: tmp, expectedBytes: 2_048))
        }

        @Test func rejectsAMissingFile() {
            let missing = FileManager.default.temporaryDirectory
                .appendingPathComponent("echo-model-missing-\(UUID().uuidString).bin")
            #expect(!OnnxKokoroEngine.fileHasExpectedSize(at: missing, expectedBytes: 2_048))
        }
    }
#endif
