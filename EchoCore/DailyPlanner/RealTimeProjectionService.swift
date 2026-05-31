import Foundation

final class RealTimeProjectionService {
    private let calendar = Calendar.current
    private let maxPlaybackSpeed: Double = 3.0

    /// Estimate when the user will finish the current book at the given speed.
    func estimateCompletion(
        currentPosition: TimeInterval,
        totalDuration: TimeInterval,
        currentSpeed: Double,
        scheduledSessions: [PlannedSession] = []
    ) -> SpeedSuggestion {
        let remaining = totalDuration - currentPosition
        let realRemaining = remaining / currentSpeed

        if scheduledSessions.isEmpty {
            let completionDate = Date().addingTimeInterval(realRemaining)
            return SpeedSuggestion(
                requiredSpeed: currentSpeed,
                availableDuration: realRemaining,
                remainingDuration: remaining,
                estimatedCompletionDate: completionDate,
                scenario: .onTrack
            )
        }

        // Total available listening time from scheduled sessions
        let now = Date()
        let futureSessions = scheduledSessions.filter { $0.endTime > now && !$0.isCompleted }
        let totalAvailableSeconds = futureSessions.reduce(0.0) { acc, session in
            acc + session.endTime.timeIntervalSince(max(session.startTime, now))
        }

        if totalAvailableSeconds <= 0 {
            let completionDate = now.addingTimeInterval(realRemaining)
            return SpeedSuggestion(
                requiredSpeed: currentSpeed,
                availableDuration: 0,
                remainingDuration: remaining,
                estimatedCompletionDate: completionDate,
                scenario: .onTrack
            )
        }

        let requiredSpeed = remaining / totalAvailableSeconds

        if requiredSpeed <= currentSpeed {
            let completionDate = now.addingTimeInterval(realRemaining)
            return SpeedSuggestion(
                requiredSpeed: currentSpeed,
                availableDuration: totalAvailableSeconds,
                remainingDuration: remaining,
                estimatedCompletionDate: completionDate,
                scenario: .onTrack
            )
        }

        if requiredSpeed <= maxPlaybackSpeed {
            let completionDate = futureSessions.map(\.endTime).max() ?? now.addingTimeInterval(realRemaining)
            return SpeedSuggestion(
                requiredSpeed: requiredSpeed,
                availableDuration: totalAvailableSeconds,
                remainingDuration: remaining,
                estimatedCompletionDate: completionDate,
                scenario: .needAdjustment(speed: requiredSpeed)
            )
        }

        // Even at max speed, content won't fit
        let completionDate = now.addingTimeInterval(remaining / maxPlaybackSpeed)
        return SpeedSuggestion(
            requiredSpeed: maxPlaybackSpeed,
            availableDuration: totalAvailableSeconds,
            remainingDuration: remaining,
            estimatedCompletionDate: completionDate,
            scenario: .insufficient
        )
    }

    /// Calculate the speed needed to finish `contentDuration` within `timeBlock`.
    func speedToFit(contentDuration: TimeInterval, in timeBlock: TimeInterval) -> Double {
        guard timeBlock > 0 else { return maxPlaybackSpeed }
        return min(maxPlaybackSpeed, contentDuration / timeBlock)
    }

    /// Predicts the wall-clock time at which a given media timestamp will be reached,
    /// based on the current playback position and speed.
    func projectedWallClock(
        for mediaTimestamp: TimeInterval,
        currentPosition: TimeInterval,
        currentRealTime: Date,
        speed: Double
    ) -> Date {
        let remaining = mediaTimestamp - currentPosition
        let realSeconds = remaining / max(speed, 0.01)
        return currentRealTime.addingTimeInterval(realSeconds)
    }

    func formatProjectedTime(_ date: Date, speed: Double) -> String {
        let timeStr = date.formatted(date: .omitted, time: .shortened)
        return "\(timeStr) at \(String(format: "%.1f", speed))x"
    }
}
