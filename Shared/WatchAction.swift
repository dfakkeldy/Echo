// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Actions available for Watch remote control and iOS settings configuration.
/// Shared across iOS, watchOS, macOS, and Widget targets.
public enum WatchAction: String, Codable, CaseIterable, Identifiable {
    case playPause
    case skipForward
    case skipBackward
    case nextTrack
    case previousTrack
    case nextSection
    case previousSection
    case loopMode
    case speed
    case sleepTimer
    case bookmark
    case pomodoro
    case empty

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .playPause:     return "playpause.fill"
        case .skipForward:   return "goforward.30"
        case .skipBackward:  return "gobackward.30"
        case .nextTrack:     return "forward.end.fill"
        case .previousTrack: return "backward.end.fill"
        case .nextSection:     return "forward.fill"
        case .previousSection: return "backward.fill"
        case .loopMode:      return "infinity"
        case .speed:         return "gauge.medium"
        case .sleepTimer:    return "moon.zzz.fill"
        case .bookmark:      return "bookmark.fill"
        case .pomodoro:      return "timer"
        case .empty:         return "plus"
        }
    }

    public func dynamicIconName(forDuration duration: Int) -> String {
        switch self {
        case .skipForward:
            let valid = [5, 10, 15, 30, 45, 60, 75, 90]
            if valid.contains(duration) {
                return "goforward.\(duration)"
            }
            return "arrow.clockwise"
        case .skipBackward:
            let valid = [5, 10, 15, 30, 45, 60, 75, 90]
            if valid.contains(duration) {
                return "gobackward.\(duration)"
            }
            return "arrow.counterclockwise"
        default:
            return iconName
        }
    }

    /// Command string sent over WatchConnectivity. Unused on iOS/macOS.
    public var command: String {
        switch self {
        case .playPause:     return "toggle"
        case .skipForward:   return "skipForward"
        case .skipBackward:  return "skipBackward"
        case .nextTrack:     return "next"
        case .previousTrack: return "previous"
        case .nextSection:     return "nextSection"
        case .previousSection: return "previousSection"
        case .loopMode:      return "cycleLoopMode"
        case .speed:         return "cycleSpeed"
        case .sleepTimer:    return "toggleSleepTimer"
        case .bookmark:      return "addBookmark"
        case .pomodoro:      return "pomodoro"
        case .empty:         return ""
        }
    }
}
