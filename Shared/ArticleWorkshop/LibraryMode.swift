// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated enum LibraryMode: String, CaseIterable, Identifiable, Sendable {
    case books
    case inbox
    case anthologies

    var id: Self { self }

    var title: String {
        switch self {
        case .books: "Books"
        case .inbox: "Inbox"
        case .anthologies: "Anthologies"
        }
    }

    var systemImage: String {
        switch self {
        case .books: "books.vertical"
        case .inbox: "tray"
        case .anthologies: "text.book.closed"
        }
    }
}

nonisolated enum LibraryModePickerPresentation: Equatable, Sendable {
    case segmented
    case menu
}

nonisolated enum LibraryModePickerPolicy {
    static let availableModes = LibraryMode.allCases

    static func presentation(isAccessibilitySize: Bool) -> LibraryModePickerPresentation {
        isAccessibilitySize ? .menu : .segmented
    }
}

nonisolated enum ArticleInboxPresentationState: String, Equatable, Sendable {
    case ready
    case reviewSuggested
    case captureFailed

    var title: String {
        switch self {
        case .ready: "Ready"
        case .reviewSuggested: "Review suggested"
        case .captureFailed: "Capture failed"
        }
    }

    var systemImage: String {
        switch self {
        case .ready: "checkmark.circle"
        case .reviewSuggested: "exclamationmark.triangle"
        case .captureFailed: "xmark.octagon"
        }
    }
}

nonisolated struct ArticleInboxItem: Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let author: String?
    let siteName: String?
    let sourceURL: String
    let canonicalURL: String?
    let capturedAt: String
    let state: ArticleInboxPresentationState
    let warnings: [String]
    let isPossibleDuplicate: Bool
    let keepBothAvailable: Bool
    let isUsed: Bool

    init(
        id: String,
        title: String,
        author: String?,
        siteName: String?,
        sourceURL: String,
        canonicalURL: String?,
        capturedAt: String,
        state: ArticleInboxPresentationState,
        warnings: [String],
        isPossibleDuplicate: Bool,
        keepBothAvailable: Bool,
        isUsed: Bool = false
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.siteName = siteName
        self.sourceURL = sourceURL
        self.canonicalURL = canonicalURL
        self.capturedAt = capturedAt
        self.state = state
        self.warnings = warnings
        self.isPossibleDuplicate = isPossibleDuplicate
        self.keepBothAvailable = keepBothAvailable
        self.isUsed = isUsed
    }

    var isAnthologyEligible: Bool {
        state != .captureFailed
    }

    var warningOccurrences: [ArticleWarningOccurrence] {
        warnings.enumerated().map { offset, warning in
            ArticleWarningOccurrence(id: offset, text: warning)
        }
    }
}

nonisolated struct ArticleWarningOccurrence: Equatable, Identifiable, Sendable {
    let id: Int
    let text: String
}

nonisolated enum ArticleDeletionImpact: Equatable, Sendable {
    case unreferenced
    case referenced(projectNames: [String])

    var projectNames: [String] {
        switch self {
        case .unreferenced: []
        case .referenced(let projectNames): projectNames
        }
    }

    var isReferenced: Bool {
        projectNames.isEmpty == false
    }
}
