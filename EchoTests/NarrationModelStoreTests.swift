// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import Echo

@Suite struct NarrationModelStoreTests {

    @Test func keptBucketsExcludeThirtySecond() {
        #expect(NarrationModelStore.keptBucketSeconds == [3, 7, 10, 15])
        #expect(!NarrationModelStore.keptBucketSeconds.contains(30))
    }

    @Test func hnsfConstantsMatchWeightsJsonExactly() {
        // hnsf_weights.json: 9 linear weights + 1 bias. Pinned verbatim so a
        // transcription drift in NarrationModelStore is caught immediately.
        #expect(NarrationModelStore.hnsfLinearWeights.count == 9)
        #expect(NarrationModelStore.hnsfLinearBias == -0.02945026)
    }

    @Test func downloadFileListPrunesLargeBuckets() {
        let files = NarrationModelStore.requiredModelFiles()

        // Kept decoder buckets (pre + har_post).
        #expect(files.contains("kokoro_decoder_pre_15s.mlpackage"))
        #expect(files.contains("kokoro_decoder_har_post_15s.mlpackage"))

        // 30s decoder buckets pruned (chunks are capped ≤15s of audio).
        #expect(!files.contains("kokoro_decoder_pre_30s.mlpackage"))
        #expect(!files.contains("kokoro_decoder_har_post_30s.mlpackage"))

        // f0ntrain: keep the four buckets that match {3,7,10,15}s; drop t1200 (30s).
        #expect(files.contains("kokoro_f0ntrain_t120.mlpackage"))
        #expect(files.contains("kokoro_f0ntrain_t600.mlpackage"))
        #expect(!files.contains("kokoro_f0ntrain_t1200.mlpackage"))

        // ALL duration buckets are small; keep every one (the pipeline picks
        // the nearest padded token size per utterance).
        #expect(files.contains("kokoro_duration.mlpackage"))
        #expect(files.contains("kokoro_duration_t512.mlpackage"))
    }

    @Test func requiredFileListIsUnique() {
        let files = NarrationModelStore.requiredModelFiles()
        #expect(files.count == Set(files).count)
    }
}
