// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import Foundation
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
    }
#endif
