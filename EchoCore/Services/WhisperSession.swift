// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os.log
@preconcurrency import WhisperKit

/// A shared, reference-counted WhisperKit model manager so multiple services
/// (AutoAlignmentService, ContinuousAlignmentService, etc.) share a single
/// in-memory model instance instead of each loading their own ~40 MB copy.
///
/// Usage:
///   let session = WhisperSession.shared
///   let wk = try await session.acquire(model: "base.en")
///   defer { await session.release() }
///   let result = await wk.transcribe(...)
@MainActor
final class WhisperSession {
    static let shared = WhisperSession()

    private let logger = Logger(category: "WhisperSession")

    /// The shared model's reference-counted lifecycle. The generation-guarded
    /// unload (and the acquire/release/forceUnload semantics) live in — and are
    /// unit-tested through — `ModelRetainBox`; this type just supplies the
    /// WhisperKit-specific load/unload closures.
    private let box: ModelRetainBox<WhisperKit>

    private init() {
        // Capture a local logger (not `self.logger`) so the closures don't
        // reference `self` during initialization.
        let logger = Logger(category: "WhisperSession")
        box = ModelRetainBox<WhisperKit>(
            load: { model in
                logger.info("WhisperSession: loading '\(model)'")
                return try await WhisperKit(model: model)
            },
            unload: { model in
                logger.info("WhisperSession: unloading model")
                await model.unloadModels()
            }
        )
    }

    /// Acquires a reference to the WhisperKit model, loading it if necessary.
    /// Callers **must** call `release()` when done to allow unloading.
    func acquire(model: String = "base.en") async throws -> WhisperKit {
        try await box.acquire(key: model)
    }

    /// Releases one reference.  When the retain count reaches zero the model
    /// is unloaded to free ~40 MB of memory.
    func release() {
        box.release()
    }

    /// Force-unloads the model regardless of retain count. Use when the
    /// audiobook changes or alignment is cancelled.
    func forceUnload() {
        box.forceUnload()
    }
}
