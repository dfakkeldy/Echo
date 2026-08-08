// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated struct ReaderViewportAnchor: Equatable, Sendable {
    let itemID: String
    let distanceFromContentOffset: Double
    let openChapterKey: Int?
}

nonisolated struct ReaderViewportPublicationContext: Equatable, Sendable {
    let bookIdentityURL: URL?
    let bookGeneration: UInt
}

nonisolated struct ReaderViewportPublication: Equatable, Sendable {
    let context: ReaderViewportPublicationContext
    let anchor: ReaderViewportAnchor
}

nonisolated struct ReaderViewportState: Equatable, Sendable {
    private(set) var bookIdentityURL: URL?
    private(set) var bookGeneration: UInt = 0
    var anchor: ReaderViewportAnchor?

    init(bookIdentityURL: URL? = nil, anchor: ReaderViewportAnchor? = nil) {
        self.bookIdentityURL = bookIdentityURL
        self.anchor = anchor
    }

    var publicationContext: ReaderViewportPublicationContext {
        ReaderViewportPublicationContext(
            bookIdentityURL: bookIdentityURL,
            bookGeneration: bookGeneration
        )
    }

    mutating func prepare(for bookIdentityURL: URL?) {
        guard self.bookIdentityURL != bookIdentityURL else { return }
        self.bookIdentityURL = bookIdentityURL
        bookGeneration &+= 1
        anchor = nil
    }

    @discardableResult
    mutating func apply(_ publication: ReaderViewportPublication) -> Bool {
        guard publication.context == publicationContext else { return false }
        if anchor != publication.anchor {
            anchor = publication.anchor
        }
        return true
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
