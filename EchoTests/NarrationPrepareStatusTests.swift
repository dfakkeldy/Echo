// SPDX-License-Identifier: GPL-3.0-or-later
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
        let d0 = NarrationPrepareStatus.batch(for: .downloadingModels(fraction: 0))
        let d1 = NarrationPrepareStatus.batch(for: .downloadingModels(fraction: 1))
        let c0 = NarrationPrepareStatus.batch(for: .compilingModels(done: 0, total: 20))
        let c1 = NarrationPrepareStatus.batch(for: .compilingModels(done: 20, total: 20))
        let ready = NarrationPrepareStatus.batch(for: .ready)

        #expect(d0.fraction == 0)
        #expect(d1.fraction <= c0.fraction)  // download band ends at/below compile band start
        #expect(c1.fraction <= ready.fraction)
        #expect(ready.fraction == 0.15)  // never exceeds the reserved prepare band
        #expect(d1.message.contains("100%"))
        #expect(c0.message == "Loading voice models… 0 of 20")
    }

    @Test func compileTotalZeroDoesNotDivideByZero() {
        let s = NarrationPrepareStatus.batch(for: .compilingModels(done: 0, total: 0))
        #expect(s.fraction.isFinite)
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

    /// Regression for the coalescing-join drop: a subscriber that joins an
    /// in-flight prepare (via `ProgressFanOut`) must still receive subsequent
    /// events, in order. Without this the iOS Listen tap that arrives after the
    /// NowPlayingTab pre-warm started the download saw no download/compile feedback.
    @Test func fanOutDeliversInOrderAndToLateJoiners() {
        let fan = ProgressFanOut()
        let early = ProgressBox()
        let late = ProgressBox()
        fan.add { early.append($0) }
        fan.emit(.downloadingModels(fraction: 0.5))
        fan.add { late.append($0) }  // joins after the first event
        fan.emit(.compilingModels(done: 1, total: 2))
        fan.emit(.ready)
        #expect(
            early.items == [
                .downloadingModels(fraction: 0.5), .compilingModels(done: 1, total: 2), .ready,
            ])
        #expect(late.items == [.compilingModels(done: 1, total: 2), .ready])
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

    /// `clear()` must reset the stored terminal state too, not just the subscriber
    /// list — otherwise a recycled fan-out would replay a stale `.ready` to a new
    /// subscriber and skip intermediate progress. After clear() a fresh subscriber
    /// receives nothing until new events are emitted, proving the box is reusable.
    @Test func clearResetsTerminalReplay() {
        let fan = ProgressFanOut()
        fan.emit(.ready)
        fan.clear()
        let box = ProgressBox()
        fan.add { box.append($0) }  // after clear — must NOT get a stale .ready replay
        #expect(box.items.isEmpty)
        fan.emit(.downloadingModels(fraction: 0.1))  // box is reusable post-clear
        #expect(box.items == [.downloadingModels(fraction: 0.1)])
    }
}
