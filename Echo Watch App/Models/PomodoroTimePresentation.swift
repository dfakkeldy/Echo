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
