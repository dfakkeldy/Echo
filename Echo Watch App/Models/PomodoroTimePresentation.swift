// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated enum PomodoroDisplayUnit: Equatable, Sendable {
    case hours
    case minutes
    case seconds
    case complete
}

nonisolated struct PomodoroTimePresentation: Equatable, Sendable {
    let digits: String
    let value: Int
    let unit: PomodoroDisplayUnit
    let isComplete: Bool
    let isOverflow: Bool

    static func make(remaining: TimeInterval) -> Self {
        guard remaining.isFinite, remaining > 0 else {
            return Self(
                digits: "00", value: 0, unit: .complete, isComplete: true, isOverflow: false)
        }

        let maximumVisibleHours = 99
        if remaining > TimeInterval(maximumVisibleHours * 3600) {
            return Self(
                digits: "99",
                value: maximumVisibleHours,
                unit: .hours,
                isComplete: false,
                isOverflow: true
            )
        }

        let value: Int
        let unit: PomodoroDisplayUnit
        if remaining > 3600 {
            value = Int(ceil(remaining / 3600))
            unit = .hours
        } else if remaining > 60 {
            value = Int(ceil(remaining / 60))
            unit = .minutes
        } else {
            value = Int(ceil(remaining))
            unit = .seconds
        }

        return Self(
            digits: value < 10 ? "0\(value)" : "\(value)",
            value: value,
            unit: unit,
            isComplete: false,
            isOverflow: false
        )
    }

    /// One-letter unit shown after the number ("25m"), so the ring reads as
    /// a timer at a glance rather than a bare number. Empty when complete.
    var unitSymbol: String {
        switch unit {
        case .hours: String(localized: "h", comment: "Pomodoro hours unit, one letter")
        case .minutes: String(localized: "m", comment: "Pomodoro minutes unit, one letter")
        case .seconds: String(localized: "s", comment: "Pomodoro seconds unit, one letter")
        case .complete: ""
        }
    }

    /// The number the button shows next to `unitSymbol`: no leading zero
    /// ("5m", not "05m"). Falls back to `digits` once complete.
    var unitNumber: String {
        unit == .complete ? digits : "\(value)"
    }

    /// The whole compact label, e.g. "25m", "45s", "2h", or "00" when complete.
    var compactLabel: String {
        unitNumber + unitSymbol
    }

    func accessibilityValue(isRunning: Bool) -> String {
        if isComplete {
            return String(localized: "Timer complete")
        }
        let state = isRunning ? String(localized: "Running") : String(localized: "Stopped")
        return "\(state), \(remainingDescription)"
    }

    func accessibilityHint(isRunning: Bool) -> String {
        isRunning
            ? String(localized: "Double-tap to stop the timer")
            : String(localized: "Double-tap to start the timer")
    }

    private var remainingDescription: String {
        if isOverflow {
            return String(localized: "More than 99 hours remaining")
        }
        switch unit {
        case .hours:
            return value == 1
                ? String(localized: "1 hour remaining")
                : String(localized: "\(value) hours remaining")
        case .minutes:
            return value == 1
                ? String(localized: "1 minute remaining")
                : String(localized: "\(value) minutes remaining")
        case .seconds:
            return value == 1
                ? String(localized: "1 second remaining")
                : String(localized: "\(value) seconds remaining")
        case .complete:
            return String(localized: "Timer complete")
        }
    }
}
