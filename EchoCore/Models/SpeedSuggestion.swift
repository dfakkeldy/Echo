// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct SpeedSuggestion: Identifiable, Equatable, Sendable {
    let id = UUID()
    let requiredSpeed: Double
    let availableDuration: TimeInterval
    let remainingDuration: TimeInterval
    let estimatedCompletionDate: Date
    let scenario: Scenario

    enum Scenario: Equatable {
        case onTrack
        case needAdjustment(speed: Double)
        case insufficient
    }

    var description: String {
        switch scenario {
        case .onTrack:
            String(localized: "On track to finish by \(formattedDate)")
        case .needAdjustment(let speed):
            String(localized: "Schedule \(String(format: "%.1f", speed))x to finish by \(formattedDate)")
        case .insufficient:
            String(localized: "Not enough time even at max speed")
        }
    }

    private static let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt
    }()

    private var formattedDate: String {
        Self.dateFormatter.string(from: estimatedCompletionDate)
    }
}
