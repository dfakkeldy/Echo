// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Dictionary keys used in the WatchConnectivity message protocol.
/// Shared across iOS (WatchCommandRouter) and watchOS (WatchViewModel).
enum WatchMessageKey {
    static let command = "command"
    static let params = "params"
}
