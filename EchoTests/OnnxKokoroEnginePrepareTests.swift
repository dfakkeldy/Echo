// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import Foundation
    import Synchronization
    import Testing

    @testable import Echo

    /// §5.11 — a thrown `prepare()` must NOT be cached. The engine stored its init
    /// `Task` once and never cleared it on failure, so a single transient model-load
    /// error (network blip, corrupt download) permanently wedged all on-device
    /// narration for the session: every later `prepare()` re-awaited the same failed
    /// task. The fix clears the cached task on failure so the next call retries.
    @Suite struct OnnxKokoroEnginePrepareTests {

        /// Counts how many times the (failing) model provider is invoked. With the
        /// bug, a cached failure means the provider runs once for many prepares;
        /// after the fix, each prepare starts a fresh attempt.
        actor CallCounter {
            private(set) var count = 0
            func increment() { count += 1 }
        }

        nonisolated final class ProgressBox: Sendable {
            private let values = Mutex<[NarrationPrepareProgress]>([])

            var items: [NarrationPrepareProgress] { values.withLock { $0 } }

            func append(_ progress: NarrationPrepareProgress) {
                values.withLock { $0.append(progress) }
            }
        }

        @Test func intraOpThreadsDefaultsToTwoAndIsInjectable() async {
            let def = OnnxKokoroEngine()
            #expect(await def.intraOpThreadsForTesting == 2)

            let custom = OnnxKokoroEngine(
                modelProvider: { _ in
                    throw NarrationError.engineUnavailable
                }, intraOpThreads: 4)
            #expect(await custom.intraOpThreadsForTesting == 4)
        }

        @Test func failedPrepareIsNotCachedSoTheNextCallRetries() async {
            let counter = CallCounter()
            let engine = OnnxKokoroEngine(modelProvider: { _ in
                await counter.increment()
                throw NarrationError.engineUnavailable
            })

            await #expect(throws: (any Error).self) { try await engine.prepare() }
            await #expect(throws: (any Error).self) { try await engine.prepare() }

            // Two prepares, two real attempts — not one cached failure replayed.
            #expect(await counter.count == 2)
        }

        @Test func providerProgressIsForwardedWithoutLosingExactBytes() async {
            let box = ProgressBox()
            let engine = OnnxKokoroEngine(modelProvider: { progress in
                progress(.checkingModel(expectedBytes: 163_234_740))
                progress(
                    .downloadingModel(
                        receivedBytes: 65_536, totalBytes: 163_234_740))
                throw NarrationError.engineUnavailable
            })

            await #expect(throws: (any Error).self) {
                try await engine.prepare(progress: { box.append($0) })
            }
            #expect(
                box.items == [
                    .checkingModel(expectedBytes: 163_234_740),
                    .downloadingModel(receivedBytes: 65_536, totalBytes: 163_234_740),
                ])
        }

        @Test func coalescedPrepareJoinerReceivesReadyExactlyOnce() async throws {
            let headURL = try #require(
                NarrationResources.url(forResource: "kokoro_dur_head", withExtension: "onnx"))
            let (providerEntered, providerEnteredContinuation) = AsyncStream<Void>.makeStream()
            let (releaseProvider, releaseProviderContinuation) = AsyncStream<Void>.makeStream()
            let (joinerSubscribed, joinerSubscribedContinuation) = AsyncStream<Void>.makeStream()
            let engine = OnnxKokoroEngine(
                modelProvider: { progress in
                    progress(.checkingModel(expectedBytes: 1))
                    providerEnteredContinuation.yield(())
                    var iterator = releaseProvider.makeAsyncIterator()
                    _ = await iterator.next()
                    return headURL
                },
                intraOpThreads: 1)
            let firstProgress = ProgressBox()
            let joinerProgress = ProgressBox()

            let first = Task {
                try await engine.prepare(progress: { firstProgress.append($0) })
            }
            var enteredIterator = providerEntered.makeAsyncIterator()
            _ = await enteredIterator.next()

            let joiner = Task {
                try await engine.prepare(progress: { progress in
                    joinerProgress.append(progress)
                    if progress == .checkingModel(expectedBytes: 1) {
                        joinerSubscribedContinuation.yield(())
                    }
                })
            }
            var subscribedIterator = joinerSubscribed.makeAsyncIterator()
            _ = await subscribedIterator.next()

            releaseProviderContinuation.yield(())
            releaseProviderContinuation.finish()
            try await first.value
            try await joiner.value

            #expect(firstProgress.items.filter { $0 == .ready }.count == 1)
            #expect(joinerProgress.items.filter { $0 == .ready }.count == 1)
        }
    }
#endif
