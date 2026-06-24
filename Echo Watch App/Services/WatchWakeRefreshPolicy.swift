// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct WatchWakeRefreshPolicy {
    private var lastRefreshDate: Date?
    private let minimumInterval: TimeInterval

    init(minimumInterval: TimeInterval = 1.0) {
        self.minimumInterval = minimumInterval
    }

    mutating func shouldRefresh(now: Date = .now) -> Bool {
        guard let lastRefreshDate else {
            self.lastRefreshDate = now
            return true
        }

        guard now.timeIntervalSince(lastRefreshDate) >= minimumInterval else {
            return false
        }

        self.lastRefreshDate = now
        return true
    }
}
