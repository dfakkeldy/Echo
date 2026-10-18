// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated enum MarkPassageResult: Equatable, Sendable {
    case saved
    case unavailable
    case failed
}

nonisolated struct MarkedPassageCaptureRequest: Equatable, Sendable {
    let audiobookID: String
    let mediaTimestamp: TimeInterval
    let endTimestamp: TimeInterval
    let transcriptSnippet: String?
}

nonisolated enum MarkedPassageCapture {
    static func capture(
        bookID: String?,
        isItemLoaded: Bool,
        time: TimeInterval,
        snippet: String?,
        persist: (MarkedPassageCaptureRequest) throws -> Void,
        onFailure: (Error) -> Void = { _ in }
    ) -> MarkPassageResult {
        guard let bookID, bookID.isEmpty == false, isItemLoaded, time.isFinite else {
            return .unavailable
        }

        let request = MarkedPassageCaptureRequest(
            audiobookID: bookID,
            mediaTimestamp: max(0, time - 15),
            endTimestamp: time + 5,
            transcriptSnippet: snippet
        )

        do {
            try persist(request)
            return .saved
        } catch {
            onFailure(error)
            return .failed
        }
    }
}
