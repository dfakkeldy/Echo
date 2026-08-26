// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated struct NarrationRenderUnitStatus: Equatable, Sendable {
    let chapterDisplayNumber: Int
    let segmentIndex: Int?
    let voiceID: VoiceID
    let completedBlocks: Int
    let totalBlocks: Int
    let startedAt: Date
    let lastProgressAt: Date

    var fraction: Double {
        guard totalBlocks > 0 else { return 0 }
        return min(1, max(0, Double(completedBlocks) / Double(totalBlocks)))
    }
}

nonisolated enum NarrationRenderActivity: Equatable, Sendable {
    case idle
    case planning
    case checkingModel(expectedBytes: Int64)
    case downloadingModel(receivedBytes: Int64, totalBytes: Int64)
    case validatingModel(byteCount: Int64)
    case loadingModel(startedAt: Date)
    case modelReady
    case rendering(NarrationRenderUnitStatus)
    case heldByBackpressure(NarrationRenderUnitStatus?)
    case complete
    case noNarratableText
    case blocked(message: String)
    case cancelled
    case failed(message: String)
}

nonisolated enum NarrationPlaybackActivity: Equatable, Sendable {
    case notStarted
    case loading(chapterDisplayNumber: Int?)
    case playing(chapterDisplayNumber: Int?)
    case paused(chapterDisplayNumber: Int?)
    case waitingForRender(chapterDisplayNumber: Int?)
    case resuming(chapterDisplayNumber: Int?)
    case stopped
    case completed
    case failed(message: String)
}

nonisolated struct NarrationBufferStatus: Equatable, Sendable {
    var totalSegments = 0
    var queuedSegments = 0
    var currentPlaybackIndex = 0

    var readyAhead: Int {
        max(0, queuedSegments - currentPlaybackIndex - 1)
    }
}

nonisolated struct NarrationEventDescriptor: Equatable, Sendable {
    enum Category: String, Equatable, Sendable {
        case preparation, model, voice, render, buffer, playback, error
    }
    enum Severity: Equatable, Sendable { case info, notice, warning, error }

    let category: Category
    let severity: Severity
    let message: String
    let developerMessage: String
    let privateDetail: String?

    init(
        category: Category, severity: Severity, message: String,
        developerMessage: String, privateDetail: String? = nil
    ) {
        self.category = category
        self.severity = severity
        self.message = message
        self.developerMessage = developerMessage
        self.privateDetail = privateDetail
    }
}

nonisolated struct NarrationEvent: Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let descriptor: NarrationEventDescriptor

    var category: NarrationEventDescriptor.Category { descriptor.category }
    var severity: NarrationEventDescriptor.Severity { descriptor.severity }
    var message: String { descriptor.message }
}

nonisolated struct NarrationStatusSnapshot: Equatable, Sendable {
    var render: NarrationRenderActivity = .idle
    var playback: NarrationPlaybackActivity = .notStarted
    var buffer = NarrationBufferStatus()
    var defaultVoiceID: VoiceID?
}

nonisolated struct NarrationRenderProgress: Equatable, Sendable {
    let chapterDisplayNumber: Int
    let segmentIndex: Int?
    let voiceID: VoiceID
    let completedBlocks: Int
    let totalBlocks: Int
    let timestamp: Date
}
