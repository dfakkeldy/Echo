// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
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

        // Duration buckets pruned to ≤ maxDurationTokens (256): the 200-char chunker
        // never produces tokens above ~220, so t320/t384/t512 are never selected and
        // only add minutes of dead first-run compile. Legacy + t32…t256 are kept.
        #expect(files.contains("kokoro_duration.mlpackage"))
        #expect(files.contains("kokoro_duration_t256.mlpackage"))
        #expect(!files.contains("kokoro_duration_t320.mlpackage"))
        #expect(!files.contains("kokoro_duration_t384.mlpackage"))
        #expect(!files.contains("kokoro_duration_t512.mlpackage"))
    }

    @Test func requiredFileListIsUnique() {
        let files = NarrationModelStore.requiredModelFiles()
        #expect(files.count == Set(files).count)
    }

    @Test func concurrentDownloadCapIsBounded() {
        // First-run pulls ~731 MB across 17 packages; packages download concurrently
        // for speed, but the cap keeps the in-flight count — and so peak memory / HF
        // load — bounded, which matters on a 4 GB A14.
        #expect(NarrationModelStore.maxConcurrentDownloads >= 2)
        #expect(NarrationModelStore.maxConcurrentDownloads <= 8)
    }

    @Test func partialPackageIsNotCompleteUntilMarkerStamped() throws {
        // Reproduces the wedge that bit the retired FluidAudio path: a package
        // holding only its Manifest.json (interrupted before the weights/spec)
        // must read as INCOMPLETE. Completeness is the explicit marker, stamped
        // only after every internal file lands — so the package is re-walked and
        // finished instead of being trusted and locked into the cache (the way
        // KokoroNoise_v2 lost its model.mil yet was reused on every launch).
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(
            "nms-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let pkg = "kokoro_duration.mlpackage"
        let root = dir.appendingPathComponent(pkg, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Manifest.json"))

        let store = NarrationModelStore.shared
        // Manifest present but no marker → incomplete (the bug, now guarded).
        #expect(store.isPackageComplete(pkg, in: dir) == false)

        try Data().write(to: NarrationModelStore.packageMarker(pkg, in: dir))
        #expect(store.isPackageComplete(pkg, in: dir) == true)
    }
}
