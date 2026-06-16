// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A reference-counted, single-instance loader for an expensive model.
///
/// Multiple services can share one in-memory model: each `acquire()` hands back
/// the same instance and bumps a retain count; the model is unloaded only once
/// the last holder calls `release()`. `forceUnload()` evicts immediately
/// (e.g. when the source material changes), regardless of outstanding holders.
///
/// A monotonic `generation` counter disambiguates a scheduled unload from a
/// later re-`acquire()`: the unload is captured against the generation that was
/// current *when it was scheduled*, and skips itself if the generation has
/// advanced (meaning someone re-acquired in the meantime).  (CODE_AUDIT.md §3.1)
@MainActor
final class ModelRetainBox<Model> {
    private var cached: Model?
    private var loadedKey: String?
    private var retainCount = 0
    private var generation = 0

    /// The most recently scheduled unload task. Tracked so callers (and tests)
    /// can await its completion, and so it can be cancelled on teardown.
    private(set) var pendingUnload: Task<Void, Never>?

    private let load: (String) async throws -> Model
    private let unload: (Model) async -> Void

    init(load: @escaping (String) async throws -> Model,
         unload: @escaping (Model) async -> Void) {
        self.load = load
        self.unload = unload
    }

    /// The currently loaded model, if any. For inspection/testing.
    var currentModel: Model? { cached }

    /// Acquires the shared model, loading it if the key differs or nothing is
    /// cached. Callers **must** balance every `acquire()` with a `release()`.
    func acquire(key: String) async throws -> Model {
        retainCount += 1
        generation &+= 1
        if let cached, loadedKey == key {
            return cached
        }
        let model = try await load(key)
        cached = model
        loadedKey = key
        return model
    }

    /// Releases one reference. When the retain count reaches zero the model is
    /// scheduled for unload.
    func release() {
        retainCount = max(0, retainCount - 1)
        guard retainCount == 0 else { return }
        scheduleUnload(ifGenerationEquals: generation)
    }

    /// Force-evicts the model regardless of retain count.
    func forceUnload() {
        retainCount = 0
        generation &+= 1
        scheduleUnload(ifGenerationEquals: generation)
    }

    /// Schedules an unload that runs only if no later `acquire()` has advanced
    /// the generation past `capturedGeneration`.
    ///
    /// `capturedGeneration` is a parameter, so it is evaluated *synchronously*
    /// at the call site — before the `Task` is ever scheduled. That is the
    /// whole point: it makes it impossible to re-read the generation late from
    /// inside the task and defeat the guard.  (CODE_AUDIT.md §3.1)
    private func scheduleUnload(ifGenerationEquals capturedGeneration: Int) {
        pendingUnload = Task {
            guard self.generation == capturedGeneration else { return }
            if let model = self.cached { await self.unload(model) }
            self.cached = nil
            self.loadedKey = nil
        }
    }
}
