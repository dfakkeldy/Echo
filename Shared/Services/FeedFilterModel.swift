// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Content-type axis of the unified-feed filter. Pure value type; no UIKit, no DB.
///
/// `matchesChapter` decides whether a whole chapter GROUP survives (Audio/Text are
/// chapter-granular per Phase-3 Trap F/F2). `matchesBlockKind` decides whether an
/// individual block survives inside a surviving group (Pics/Pics+Audio are block-granular
/// per Trap E). `.bookmarks` / `.cards` are placeholders until Phase 2 adds the
/// corresponding `ReaderCardItem` cases — their predicates are pass-throughs today.
public enum FeedContentType: String, CaseIterable, Sendable {
    case everything
    case audio
    case text
    case pics
    case picsAndAudio
    case bookmarks
    case cards

    /// Whether a chapter group with the given has-audio flag survives this filter.
    /// Chapter-level filters (audio/text) drop whole groups; block-level filters
    /// (pics/picsAndAudio/bookmarks/cards) keep every group and filter items instead.
    public func matchesChapter(hasAudio: Bool) -> Bool {
        switch self {
        case .everything: return true
        case .audio: return hasAudio
        case .text: return !hasAudio
        case .pics, .picsAndAudio, .bookmarks, .cards: return true
        }
    }

    /// Whether an individual block of the given kind, in a chapter with the given
    /// has-audio flag, survives this filter. Chapter-level filters keep every block
    /// in a surviving group. `EPubBlockRecord.Kind.image.rawValue == "image"`.
    public func matchesBlockKind(_ blockKind: String, hasAudio: Bool) -> Bool {
        switch self {
        case .everything, .audio, .text:
            return true
        case .pics:
            return blockKind == "image"
        case .picsAndAudio:
            return blockKind == "image" && hasAudio
        case .bookmarks, .cards:
            // Phase 2 adds bookmark/card ReaderCardItem cases; until then these chips
            // ship disabled and never reach here. Pass-through keeps the group intact.
            return true
        }
    }

    /// True when this filter narrows individual blocks within a surviving group.
    /// Chapter-level filters (everything/audio/text) do not item-filter.
    public var isBlockLevel: Bool {
        switch self {
        case .everything, .audio, .text: return false
        case .pics, .picsAndAudio, .bookmarks, .cards: return true
        }
    }
}

/// Scope axis of the unified-feed filter. `lastSession` is resolved to a concrete
/// `session(id:startedAt:endedAt:)` by `FeedScopeResolver`; the explicit case is kept
/// for a future session picker (spec §6 "Sessions…", deferred this phase).
public enum FeedScope: Equatable, Sendable {
    case wholeBook
    case lastSession
    case session(id: String, startedAt: Date, endedAt: Date)
}

/// The two-dimensional unified-feed filter.
public struct FeedFilter: Equatable, Sendable {
    public var contentType: FeedContentType
    public var scope: FeedScope

    public init(contentType: FeedContentType = .everything, scope: FeedScope = .wholeBook) {
        self.contentType = contentType
        self.scope = scope
    }
}
