// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Which slice of the book the reader feed is currently scoped to.
public enum SessionScope: Equatable, Sendable {
    case wholeBook
    /// Audio position window in seconds (a reconstructed session's range).
    case session(start: TimeInterval, end: TimeInterval)
}

/// Pure filter: maps a session scope to the set of block ids whose audio start
/// time falls inside the session's audio-position window. UI-free and DB-free so
/// both iOS and macOS can reuse it.
public enum SessionScopeReducer {
    /// - Returns: `nil` for `.wholeBook` (apply no filter); otherwise the set of
    ///   block ids whose `audioStartTime` is within `[start, end]`.
    public static func blockIDsInScope(
        audioStartTimeByBlockID: [String: TimeInterval],
        scope: SessionScope
    ) -> Set<String>? {
        switch scope {
        case .wholeBook:
            return nil
        case .session(let start, let end):
            let lo = min(start, end)
            let hi = max(start, end)
            var result = Set<String>()
            for (blockID, t) in audioStartTimeByBlockID where t >= lo && t <= hi {
                result.insert(blockID)
            }
            return result
        }
    }
}
