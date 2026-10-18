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
    case tableOfContents
}

nonisolated struct ReaderPendingScrollRequest: Equatable, Sendable {
    let intent: ReaderScrollIntent
    let blockID: String
    let wordIndex: Int?
    let scrollGeneration: UInt
    let operationToken: UInt
    let snapshotGeneration: UInt

    func rebinding(to snapshotGeneration: UInt) -> Self {
        Self(
            intent: intent,
            blockID: blockID,
            wordIndex: wordIndex,
            scrollGeneration: scrollGeneration,
            operationToken: operationToken,
            snapshotGeneration: snapshotGeneration
        )
    }
}

/// Owns the generation and operation-token contract for every delayed Reader
/// viewport mutation. A request is valid only while it remains the latest
/// operation, survives its originating user-scroll generation, and is bound to
/// the most recently completed relevant diffable snapshot.
nonisolated struct ReaderScrollOperationState: Equatable, Sendable {
    private(set) var latestOperationToken: UInt = 0
    private(set) var snapshotGeneration: UInt = 0
    private(set) var completedSnapshotGeneration: UInt = 0
    private(set) var snapshotIsApplying = false
    private var pendingRequest: ReaderPendingScrollRequest?
    private var executingRequest: ReaderPendingScrollRequest?

    @discardableResult
    mutating func enqueue(
        intent: ReaderScrollIntent,
        blockID: String,
        wordIndex: Int?,
        scrollGeneration: UInt
    ) -> ReaderPendingScrollRequest? {
        if (pendingRequest?.intent == .returnToCurrent
            || executingRequest?.intent == .returnToCurrent)
            && intent == .followPlayback
        {
            return nil
        }
        latestOperationToken &+= 1
        executingRequest = nil
        let request = ReaderPendingScrollRequest(
            intent: intent,
            blockID: blockID,
            wordIndex: wordIndex,
            scrollGeneration: scrollGeneration,
            operationToken: latestOperationToken,
            snapshotGeneration: snapshotIsApplying
                ? snapshotGeneration : completedSnapshotGeneration
        )
        pendingRequest = request
        return request
    }

    @discardableResult
    mutating func beginSnapshot() -> UInt {
        snapshotGeneration &+= 1
        snapshotIsApplying = true
        if let pendingRequest, pendingRequest.operationToken == latestOperationToken {
            self.pendingRequest = pendingRequest.rebinding(to: snapshotGeneration)
        }
        if let executingRequest {
            self.executingRequest = nil
            if executingRequest.operationToken == latestOperationToken {
                pendingRequest = executingRequest.rebinding(to: snapshotGeneration)
            }
        }
        return snapshotGeneration
    }

    mutating func completeSnapshot(_ generation: UInt) {
        guard generation == snapshotGeneration else { return }
        completedSnapshotGeneration = generation
        snapshotIsApplying = false
    }

    mutating func takeReadyRequest() -> ReaderPendingScrollRequest? {
        guard
            snapshotIsApplying == false,
            let pendingRequest,
            pendingRequest.operationToken == latestOperationToken,
            pendingRequest.snapshotGeneration == completedSnapshotGeneration
        else { return nil }
        self.pendingRequest = nil
        executingRequest = pendingRequest
        return pendingRequest
    }

    func mayExecute(
        _ request: ReaderPendingScrollRequest,
        currentScrollGeneration: UInt
    ) -> Bool {
        request.scrollGeneration == currentScrollGeneration
            && request.operationToken == latestOperationToken
            && request.snapshotGeneration == completedSnapshotGeneration
            && snapshotIsApplying == false
            && executingRequest == request
    }

    mutating func finish(_ request: ReaderPendingScrollRequest) {
        guard executingRequest == request else { return }
        executingRequest = nil
    }

    mutating func invalidateForUserDrag() {
        latestOperationToken &+= 1
        pendingRequest = nil
        executingRequest = nil
    }
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
        case .returnToCurrent, .tableOfContents:
            return true
        }
    }
}

/// Coalesces durable ingestion generations with the transient notification
/// fast-path. A completed ticket is consumed so revisiting Reader does not
/// repeat a full reload when nothing newer arrived while it was offscreen.
nonisolated struct ReaderIngestionReloadTracker: Equatable, Sendable {
    nonisolated struct Ticket: Equatable, Sendable {
        let generation: Int
        let notificationToken: UInt
    }

    private(set) var completedGeneration: Int
    private var requestedGeneration: Int
    private var notificationToken: UInt = 0
    private var completedNotificationToken: UInt = 0

    init(completedGeneration: Int = 0) {
        self.completedGeneration = completedGeneration
        requestedGeneration = completedGeneration
    }

    mutating func markInitialLoadCompleted(generation: Int) {
        completedGeneration = max(completedGeneration, generation)
        requestedGeneration = max(requestedGeneration, completedGeneration)
    }

    @discardableResult
    mutating func requestReload(generation: Int, receivedNotification: Bool) -> Bool {
        if receivedNotification {
            notificationToken &+= 1
        }
        requestedGeneration = max(requestedGeneration, generation)
        return requestedGeneration > completedGeneration
            || notificationToken > completedNotificationToken
    }

    func nextPendingReload() -> Ticket? {
        guard
            requestedGeneration > completedGeneration
                || notificationToken > completedNotificationToken
        else { return nil }
        return Ticket(
            generation: requestedGeneration,
            notificationToken: notificationToken
        )
    }

    mutating func complete(_ ticket: Ticket?) {
        guard let ticket else { return }
        completedGeneration = max(completedGeneration, ticket.generation)
        completedNotificationToken = max(completedNotificationToken, ticket.notificationToken)
    }
}
