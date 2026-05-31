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

    private let logger = Logger(subsystem: "com.orbitaudiobooks", category: "WhisperSession")

    private var cachedModel: WhisperKit?
    private var modelSize: String?
    private var retainCount: Int = 0

    private init() {}

    /// Acquires a reference to the WhisperKit model, loading it if necessary.
    /// Callers **must** call `release()` when done to allow unloading.
    func acquire(model: String = "base.en") async throws -> WhisperKit {
        retainCount += 1
        if let cached = cachedModel, modelSize == model {
            logger.debug("WhisperSession: reusing cached '\(model)' (retainCount=\(self.retainCount))")
            return cached
        }
        logger.info("WhisperSession: loading '\(model)' (retainCount=\(self.retainCount))")
        let wk = try await WhisperKit(model: model)
        cachedModel = wk
        modelSize = model
        return wk
    }

    /// Releases one reference.  When the retain count reaches zero the model
    /// is unloaded to free ~40 MB of memory.
    func release() {
        retainCount = max(0, retainCount - 1)
        if retainCount == 0 {
            logger.info("WhisperSession: retainCount=0, unloading model")
            Task {
                await cachedModel?.unloadModels()
                cachedModel = nil
                modelSize = nil
            }
        } else {
            logger.debug("WhisperSession: release (retainCount=\(self.retainCount))")
        }
    }

    /// Force-unloads the model regardless of retain count. Use when the
    /// audiobook changes or alignment is cancelled.
    func forceUnload() {
        retainCount = 0
        Task {
            await cachedModel?.unloadModels()
            cachedModel = nil
            modelSize = nil
        }
    }
}
