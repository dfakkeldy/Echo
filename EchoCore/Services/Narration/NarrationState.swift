import Foundation
import Observation

/// Observable progress for narration rendering. Mirrors AutoAlignmentState.
@MainActor @Observable
final class NarrationState {
    enum Phase: String, Sendable {
        case idle
        case preparingChapter  // cold start / seek: rendering the current chapter
        case renderingAhead  // playing, rendering the next chapter in background
        case completed
        case failed
    }

    var phase: Phase = .idle
    var progress: Double = 0.0
    var statusMessage: String = ""
    var currentChapterIndex: Int = 0
    var totalChapters: Int = 0
    var renderedChapterCount: Int = 0
    var errorMessage: String?
    var debugLog: [String] = []

    var isRunning: Bool {
        switch phase {
        case .idle, .completed, .failed: return false
        case .preparingChapter, .renderingAhead: return true
        }
    }

    func log(_ message: String) { debugLog.append(message) }

    func update(phase: Phase, progress: Double, statusMessage: String) {
        self.phase = phase
        self.progress = progress
        self.statusMessage = statusMessage
    }

    func fail(_ message: String) {
        phase = .failed
        errorMessage = message
    }

    func complete() {
        phase = .completed
        progress = 1.0
    }

    func reset() {
        phase = .idle
        progress = 0
        statusMessage = ""
        currentChapterIndex = 0
        renderedChapterCount = 0
        errorMessage = nil
        debugLog.removeAll()
    }
}
