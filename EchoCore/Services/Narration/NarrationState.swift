// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation
import OSLog

/// Observable progress for narration rendering. Mirrors AutoAlignmentState.
@MainActor @Observable
final class NarrationState {
    enum Phase: String, Sendable {
        case idle
        case preparingEngine  // one-time model delivery + ONNX session load
        case preparingChapter  // cold start / seek: rendering the current chapter
        case renderingAhead  // playing, rendering the next chapter in background
        case completed
        case failed
    }

    private(set) var snapshot = NarrationStatusSnapshot()
    private(set) var events: [NarrationEvent] = []
    private(set) var hasSession = false

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Echo",
        category: "NarrationStatus")
    private let eventLimit = 200
    private var lastDownloadMilestone = -1

    var phase: Phase {
        switch (snapshot.render, snapshot.playback) {
        case (.failed(_), _), (.blocked(_), _), (_, .failed(_)):
            return .failed
        case (.complete, .completed):
            return .completed
        case (.checkingModel(_), _), (.downloadingModel(_, _), _),
             (.validatingModel(_), _), (.loadingModel(_), _), (.modelReady, _):
            return .preparingEngine
        case (.rendering(_), .playing(_)), (.heldByBackpressure(_), .playing(_)):
            return .renderingAhead
        case (.planning, _), (.rendering(_), _), (.heldByBackpressure(_), _):
            return .preparingChapter
        default:
            return .idle
        }
    }

    var isRunning: Bool {
        switch snapshot.render {
        case .planning, .checkingModel, .downloadingModel, .validatingModel, .loadingModel,
             .rendering, .heldByBackpressure:
            return true
        default:
            return false
        }
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
        snapshot = NarrationStatusSnapshot()
        events.removeAll()
        hasSession = false
        lastDownloadMilestone = -1
    }
}
