// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Synchronization
import Testing

@testable import Echo

@Suite struct NarrationPrepareStatusTests {
    private nonisolated final class ProgressBox: Sendable {
        private let itemsStore = Mutex<[NarrationPrepareProgress]>([])

        var items: [NarrationPrepareProgress] {
            itemsStore.withLock { $0 }
        }

        func append(_ item: NarrationPrepareProgress) {
            itemsStore.withLock { items in
                items.append(item)
            }
        }
    }

    @Test func mapsMonotonicallyIntoTheReservedFirstBand() {
        let checking = NarrationPrepareStatus.batch(for: .checkingModel(expectedBytes: 100_000_000))
        let d0 = NarrationPrepareStatus.batch(
            for: .downloadingModel(receivedBytes: 0, totalBytes: 100_000_000))
        let d1 = NarrationPrepareStatus.batch(
            for: .downloadingModel(receivedBytes: 100_000_000, totalBytes: 100_000_000))
        let validating = NarrationPrepareStatus.batch(for: .validatingModel(byteCount: 100_000_000))
        let loading = NarrationPrepareStatus.batch(for: .loadingModel)
        let ready = NarrationPrepareStatus.batch(for: .ready)

        #expect(checking.fraction == 0)
        #expect(d0.fraction == 0)
        #expect(d1.fraction <= validating.fraction)
        #expect(validating.fraction <= loading.fraction)
        #expect(loading.fraction <= ready.fraction)
        #expect(ready.fraction == 0.15)  // never exceeds the reserved prepare band
        #expect(d1.message.contains("100%"))
        #expect(loading.message == "Loading narration model…")
    }

    @Test func downloadTotalZeroDoesNotDivideByZero() {
        let s = NarrationPrepareStatus.batch(
            for: .downloadingModel(receivedBytes: 0, totalBytes: 0))
        #expect(s.fraction.isFinite)
    }

    @Test func reportsExactBatchModelDeliveryText() {
        let downloading = NarrationPrepareStatus.batch(
            for: .downloadingModel(
                receivedBytes: 50_000_000, totalBytes: 100_000_000))
        let cached = NarrationPrepareStatus.batch(
            for: .modelCacheHit(byteCount: 163_234_740))

        #expect(downloading.message == "Downloading narration model… 50% · 50 of 100 MB")
        #expect(cached.message == "Narration model cached · 163 MB")
    }

    @Test func catalogContainsNarrationPreparationMessages() throws {
        let catalogURL = try repositoryRoot().appending(path: "EchoCore/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "Localizable.xcstrings must be a JSON object.")
        let strings = try #require(
            root["strings"] as? [String: Any],
            "Localizable.xcstrings must contain strings.")

        for key in [
            "Checking narration model…",
            "Narration model cached",
            "Narration model cached · %lld MB",
            "Downloading narration model… %lld%%",
            "Downloading narration model… %lld%% · %lld of %lld MB",
            "Validating narration model…",
            "Validating narration model… %lld MB",
            "Loading narration model…",
            "Narration model ready",
        ] {
            let entry = try #require(
                strings[key] as? [String: Any], "Missing catalog key: \(key)")
            let localizations = try #require(
                entry["localizations"] as? [String: Any],
                "Missing localizations for: \(key)")
            #expect(localizations["en"] != nil, "Missing English localization: \(key)")
            #expect(localizations["nl"] != nil, "Missing Dutch localization: \(key)")
        }
    }

    /// Regression: `prepare(progress:)` must reach a concrete engine's override
    /// when called through the `any TTSEngine` existential — which is how
    /// `NarrationService.tts` and the macOS/iOS surfaces call it. If it lives
    /// only in a protocol extension (not a protocol requirement), the existential
    /// call resolves statically to the no-op default, every progress event is
    /// silently dropped, and the queue sits on "Narrating chapter 1" with no
    /// feedback even though the engine is busy downloading + compiling.
    @Test func prepareProgressReachesConcreteOverrideThroughExistential() async throws {
        final class Recorder: TTSEngine, @unchecked Sendable {
            func prepare() async throws {}
            func prepare(
                progress: @escaping @Sendable (NarrationPrepareProgress) -> Void
            ) async throws {
                progress(.ready)
            }
            func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk {
                TTSChunk(samples: [], sampleRate: 24_000, duration: 0)
            }
        }
        let box = ProgressBox()
        let engine: any TTSEngine = Recorder()
        try await engine.prepare(progress: { box.append($0) })
        #expect(box.items == [.ready])
    }

    @Test func defaultPrepareProgressFinishesReady() async throws {
        final class DefaultEngine: TTSEngine, @unchecked Sendable {
            func prepare() async throws {}
            func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk {
                TTSChunk(samples: [], sampleRate: 24_000, duration: 0)
            }
        }

        let box = ProgressBox()
        let engine: any TTSEngine = DefaultEngine()
        try await engine.prepare(progress: { box.append($0) })
        #expect(box.items == [.ready])
    }

    /// Regression for the coalescing-join drop: a subscriber that joins an
    /// in-flight prepare (via `ProgressFanOut`) must still receive subsequent
    /// events, in order. Without this the iOS Listen tap that arrives after the
    /// NowPlayingTab pre-warm started the download saw no download/compile feedback.
    @Test func fanOutDeliversInOrderAndToLateJoiners() {
        let fan = ProgressFanOut()
        let early = ProgressBox()
        let late = ProgressBox()
        fan.add { early.append($0) }
        fan.emit(.downloadingModel(receivedBytes: 50, totalBytes: 100))
        fan.add { late.append($0) }  // joins after the first event
        fan.emit(.validatingModel(byteCount: 100))
        fan.emit(.loadingModel)
        fan.emit(.ready)
        #expect(
            early.items == [
                .downloadingModel(receivedBytes: 50, totalBytes: 100),
                .validatingModel(byteCount: 100), .loadingModel, .ready,
            ])
        #expect(
            late.items == [
                .downloadingModel(receivedBytes: 50, totalBytes: 100),
                .validatingModel(byteCount: 100), .loadingModel, .ready,
            ])
    }

    @Test func fanOutReplaysLatestProgressToLateJoiner() {
        let fan = ProgressFanOut()
        let late = ProgressBox()
        fan.emit(.downloadingModel(receivedBytes: 50, totalBytes: 100))
        fan.add { late.append($0) }
        #expect(late.items == [.downloadingModel(receivedBytes: 50, totalBytes: 100)])
    }

    /// Terminal-replay: a subscriber added AFTER `.ready` has already been emitted
    /// must immediately receive `.ready` via replay, not be silently dropped.
    /// This defends against a race where a caller joins after the engine's prepare
    /// task completes; without replay the subscriber sees nothing and a UI spinner
    /// could stall indefinitely.
    @Test func lateJoinerAfterReadyGetsTerminalReplay() {
        let fan = ProgressFanOut()
        fan.emit(.ready)  // terminal event emitted before any subscriber exists
        let box = ProgressBox()
        fan.add { box.append($0) }  // late joiner — after .ready
        #expect(box.items == [.ready])
    }

    /// `clear()` must reset the stored latest state too, not just the subscriber
    /// list — otherwise a recycled fan-out could replay stale progress to a new
    /// subscriber. After clear() a fresh subscriber receives nothing until new
    /// events are emitted, proving the box is reusable.
    @Test func clearResetsLatestReplay() {
        let fan = ProgressFanOut()
        fan.emit(.ready)
        fan.clear()
        let box = ProgressBox()
        fan.add { box.append($0) }  // after clear — must NOT get a stale .ready replay
        #expect(box.items.isEmpty)
        fan.emit(.downloadingModel(receivedBytes: 10, totalBytes: 100))
        #expect(box.items == [.downloadingModel(receivedBytes: 10, totalBytes: 100)])
    }

    private func repositoryRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.deletingLastPathComponent()
            if FileManager.default.fileExists(
                atPath: candidate.appending(path: "Echo.xcodeproj").path)
            {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
