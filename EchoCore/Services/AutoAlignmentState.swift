import Foundation
import Observation

/// Observable state for the auto-alignment progress UI.
@MainActor @Observable
final class AutoAlignmentState {

    /// Current phase of the auto-alignment pipeline.
    enum Phase: String, Sendable {
        case idle
        case loadingModel
        case tier1_ChapterSnap
        case tier2_DriftDetection
        case tier3_DriftRepair
        case completed
        case failed
    }

    // MARK: - Published State

    var phase: Phase = .idle
    var progress: Double = 0.0
    var statusMessage: String = ""
    var currentChapterIndex: Int = 0
    var totalChapters: Int = 0
    var anchoredChapterCount: Int = 0
    var driftedChapterIDs: [Int] = []
    var repairAnchorCount: Int = 0
    var errorMessage: String?

    /// Accumulated diagnostic log for debugging alignment decisions.
    var debugLog: [String] = []

    /// Append a timestamped entry to the debug log.
    func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let ts = formatter.string(from: Date())
        debugLog.append("[\(ts)] \(message)")
    }

    /// Whether a pipeline is actively running.
    var isRunning: Bool {
        switch phase {
        case .idle, .completed, .failed: return false
        default: return true
        }
    }

    // MARK: - Mutations

    func reset() {
        phase = .idle
        progress = 0.0
        statusMessage = ""
        currentChapterIndex = 0
        totalChapters = 0
        anchoredChapterCount = 0
        driftedChapterIDs = []
        repairAnchorCount = 0
        errorMessage = nil
        debugLog = []
    }

    func update(phase: Phase, progress: Double, statusMessage: String) {
        self.phase = phase
        self.progress = progress
        self.statusMessage = statusMessage
    }

    func fail(_ message: String) {
        phase = .failed
        errorMessage = message
        statusMessage = message
    }

    func complete() {
        phase = .completed
        progress = 1.0
        statusMessage = "Auto-alignment complete"
    }
}
