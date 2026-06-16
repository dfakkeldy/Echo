// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
import Foundation
@testable import Echo

/// Exercises the reference-counted model lifecycle that backs `WhisperSession`.
/// The headline case reproduces CODE_AUDIT.md §3.1: a `forceUnload()` whose
/// generation snapshot was captured too late would evict a model that a later
/// `acquire()` had already handed back to a live caller.
@MainActor
struct ModelRetainBoxTests {

    /// Stand-in for a loaded ML model. Reference type so identity (`===`) and
    /// the unloaded flag are observable across the lifecycle.
    private final class FakeModel {
        let id: Int
        var isUnloaded = false
        init(id: Int) { self.id = id }
    }

    private func makeBox() -> (box: ModelRetainBox<FakeModel>, loadCount: () -> Int) {
        var loads = 0
        let box = ModelRetainBox<FakeModel>(
            load: { _ in
                loads += 1
                return FakeModel(id: loads)
            },
            unload: { model in model.isUnloaded = true }
        )
        return (box, { loads })
    }

    // MARK: - §3.1 regression

    @Test func forceUnloadDoesNotEvictAModelReacquiredBeforeTheUnloadRuns() async throws {
        let (box, _) = makeBox()

        let first = try await box.acquire(key: "base.en")
        box.forceUnload()                                   // schedules unload for the current generation
        let reacquired = try await box.acquire(key: "base.en")  // bumps the generation again
        await box.pendingUnload?.value                       // let the scheduled unload actually run

        // The model a live caller is holding must survive the stale unload.
        #expect(reacquired === first)
        #expect(first.isUnloaded == false)
        #expect(box.currentModel === first)
    }

    // MARK: - The guard must not over-correct

    @Test func releasingTheLastReferenceUnloadsTheModel() async throws {
        let (box, _) = makeBox()

        let model = try await box.acquire(key: "base.en")
        box.release()
        await box.pendingUnload?.value

        #expect(model.isUnloaded == true)
        #expect(box.currentModel == nil)
    }

    @Test func releasingOneOfSeveralReferencesKeepsTheModelLoaded() async throws {
        let (box, _) = makeBox()

        let model = try await box.acquire(key: "base.en")
        _ = try await box.acquire(key: "base.en")
        box.release()                       // retainCount drops 2 → 1, not to zero
        await box.pendingUnload?.value      // nil when no unload was scheduled

        #expect(model.isUnloaded == false)
        #expect(box.currentModel === model)
    }
}
