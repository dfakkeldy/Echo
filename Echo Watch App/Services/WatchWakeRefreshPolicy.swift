// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct WatchWakeRefreshPolicy {
    private var lastRefreshDate: Date?
    private let minimumInterval: TimeInterval

    init(minimumInterval: TimeInterval = 1.0) {
        self.minimumInterval = minimumInterval
    }

    func canRefresh(now: Date = .now) -> Bool {
        guard let lastRefreshDate else {
            return true
        }

        return now.timeIntervalSince(lastRefreshDate) >= minimumInterval
    }

    mutating func recordRefresh(now: Date = .now) {
        self.lastRefreshDate = now
    }

    mutating func shouldRefresh(now: Date = .now) -> Bool {
        guard canRefresh(now: now) else { return false }
        recordRefresh(now: now)
        return true
    }
}
