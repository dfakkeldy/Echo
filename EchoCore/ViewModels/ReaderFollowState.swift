// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated struct ReaderViewportAnchor: Equatable, Sendable {
    let itemID: String
    let distanceFromContentOffset: Double
}

nonisolated struct ReaderViewportState: Equatable, Sendable {
    private(set) var bookIdentityURL: URL?
    var anchor: ReaderViewportAnchor?

    init(bookIdentityURL: URL? = nil, anchor: ReaderViewportAnchor? = nil) {
        self.bookIdentityURL = bookIdentityURL
        self.anchor = anchor
    }

    mutating func prepare(for bookIdentityURL: URL?) {
        guard self.bookIdentityURL != bookIdentityURL else { return }
        self.bookIdentityURL = bookIdentityURL
        anchor = nil
    }
}

nonisolated struct ReaderReturnRequestTracker: Equatable, Sendable {
    private(set) var lastClaimedRequest = 0

    func hasPending(_ request: Int) -> Bool {
        request != 0 && request != lastClaimedRequest
    }

    mutating func claim(_ request: Int) -> Bool {
        guard hasPending(request) else { return false }
        lastClaimedRequest = request
        return true
    }
}

nonisolated enum ReaderFollowState: Equatable, Sendable {
    case following
    case exploring

    var allowsPlaybackMovement: Bool { self == .following }

    mutating func detachForExploration() {
        self = .exploring
    }

    @discardableResult
    mutating func completeReturn(targetResolved: Bool) -> Bool {
        guard targetResolved else { return false }
        self = .following
        return true
    }
}

nonisolated enum ReaderScrollIntent: Equatable, Sendable {
    case followPlayback
    case returnToCurrent
}

nonisolated enum ReaderScrollPermission {
    static func allows(
        intent: ReaderScrollIntent,
        followState: ReaderFollowState,
        scheduledGeneration: UInt,
        currentGeneration: UInt
    ) -> Bool {
        guard scheduledGeneration == currentGeneration else { return false }
        switch intent {
        case .followPlayback:
            return followState.allowsPlaybackMovement
        case .returnToCurrent:
            return true
        }
    }
}
