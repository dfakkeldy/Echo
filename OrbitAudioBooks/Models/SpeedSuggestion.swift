import Foundation

struct SpeedSuggestion: Identifiable, Equatable {
    let id = UUID()
    let requiredSpeed: Double
    let availableDuration: TimeInterval
    let remainingDuration: TimeInterval
    let estimatedCompletionDate: Date
    let scenario: Scenario

    enum Scenario: Equatable {
        case onTrack
        case needAdjustment(speed: Double)
        case insufficient(Double) // shortfall multiplier even at max speed
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

    private var formattedDate: String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: estimatedCompletionDate)
    }
}
