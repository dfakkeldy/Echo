// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation
import OSLog

/// Observable progress for narration rendering. Mirrors AutoAlignmentState.
@MainActor @Observable
final class NarrationState {
    enum Phase: String, Sendable {
        case idle
        case preparingEngine  // one-time model download + CoreML compile
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
    private(set) var snapshot = NarrationStatusSnapshot()
    private(set) var events: [NarrationEvent] = []
    private(set) var hasSession = false

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Echo",
        category: "NarrationStatus")
    private let eventLimit = 200
    private var lastDownloadMilestone = -1

    var isRunning: Bool {
        switch snapshot.render {
        case .planning, .checkingModel, .downloadingModel, .validatingModel, .loadingModel,
             .rendering, .heldByBackpressure:
            return true
        default:
            break
        }
        switch phase {
        case .idle, .completed, .failed: return false
        case .preparingEngine, .preparingChapter, .renderingAhead: return true
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

    func beginSession(defaultVoiceID: VoiceID, at date: Date = Date()) {
        snapshot = NarrationStatusSnapshot(defaultVoiceID: defaultVoiceID)
        events.removeAll()
        hasSession = true
        lastDownloadMilestone = -1
        record(
            .init(
                category: .preparation,
                severity: .notice,
                message: String(localized: "Narration requested"),
                developerMessage: "narration requested"),
            at: date)
    }

    func transitionRender(
        to activity: NarrationRenderActivity,
        event: NarrationEventDescriptor?,
        at date: Date = Date()
    ) {
        snapshot.render = activity
        if let event {
            record(event, at: date)
        }
    }

    func transitionPlayback(
        to activity: NarrationPlaybackActivity,
        event: NarrationEventDescriptor?,
        at date: Date = Date()
    ) {
        snapshot.playback = activity
        if let event {
            record(event, at: date)
        }
    }

    func updateBuffer(_ buffer: NarrationBufferStatus) {
        snapshot.buffer = buffer
    }

    @discardableResult
    func reportModelDownload(
        receivedBytes: Int64,
        totalBytes: Int64,
        at date: Date = Date()
    ) -> Bool {
        let clampedTotalBytes = max(0, totalBytes)
        let clampedReceivedBytes = min(max(0, receivedBytes), clampedTotalBytes)
        snapshot.render = .downloadingModel(
            receivedBytes: clampedReceivedBytes,
            totalBytes: clampedTotalBytes)

        let milestone: Int
        if clampedTotalBytes > 0 {
            milestone = min(
                20,
                Int((Double(clampedReceivedBytes) / Double(clampedTotalBytes) * 20).rounded(.down)))
        } else {
            milestone = 0
        }
        guard milestone > lastDownloadMilestone else { return false }

        lastDownloadMilestone = milestone
        record(
            .init(
                category: .model,
                severity: .info,
                message: String(localized: "Downloading model (\(milestone * 5)%)"),
                developerMessage: "model download received=\(clampedReceivedBytes) total=\(clampedTotalBytes)"),
            at: date)
        return true
    }

    func record(_ descriptor: NarrationEventDescriptor, at date: Date = Date()) {
        let event = NarrationEvent(id: UUID(), timestamp: date, descriptor: descriptor)
        events.append(event)
        if events.count > eventLimit {
            events.removeFirst(events.count - eventLimit)
        }
        switch (descriptor.severity, descriptor.privateDetail) {
        case (.info, .some(let detail)):
            logger.info("\(descriptor.developerMessage, privacy: .public) detail=\(detail, privacy: .private)")
        case (.notice, .some(let detail)):
            logger.notice("\(descriptor.developerMessage, privacy: .public) detail=\(detail, privacy: .private)")
        case (.warning, .some(let detail)):
            logger.warning("\(descriptor.developerMessage, privacy: .public) detail=\(detail, privacy: .private)")
        case (.error, .some(let detail)):
            logger.error("\(descriptor.developerMessage, privacy: .public) detail=\(detail, privacy: .private)")
        case (.info, nil): logger.info("\(descriptor.developerMessage, privacy: .public)")
        case (.notice, nil): logger.notice("\(descriptor.developerMessage, privacy: .public)")
        case (.warning, nil): logger.warning("\(descriptor.developerMessage, privacy: .public)")
        case (.error, nil): logger.error("\(descriptor.developerMessage, privacy: .public)")
        }
    }

    func reset() {
        phase = .idle
        progress = 0
        statusMessage = ""
        currentChapterIndex = 0
        renderedChapterCount = 0
        errorMessage = nil
        debugLog.removeAll()
        snapshot = NarrationStatusSnapshot()
        events.removeAll()
        hasSession = false
        lastDownloadMilestone = -1
    }
}
