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
            String(localized: "Schedule \(formattedSpeed(speed))x to finish by \(formattedDate)")
        case .insufficient:
            String(localized: "Not enough time even at max speed")
        }
    }

    private var formattedDate: String {
        estimatedCompletionDate.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    private func formattedSpeed(_ speed: Double) -> String {
        speed.formatted(.number.precision(.fractionLength(1)))
    }
}
