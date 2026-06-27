// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if os(iOS)
    import StoreKit
    import UIKit
#endif

enum ReviewPromptActivationEvent: String, Codable, Sendable {
    case bookmarkCreated
    case flashcardCreated
    case flashcardReviewed
    case studyCardReviewed
}

struct ReviewPromptSnapshot: Equatable, Sendable {
    var sessionCount: Int
    var firstLaunchDate: Date?
    var activationEventCount: Int
    var lastActivationDate: Date?
    var lastPromptAttemptDate: Date?
}

struct ReviewPromptRules: Equatable, Sendable {
    var minimumSessions: Int
    var minimumDaysSinceFirstLaunch: Int
    var minimumActivationEvents: Int
    var cooldownDays: Int
    var minimumSessionInterval: TimeInterval

    nonisolated static let echoDefault = ReviewPromptRules(
        minimumSessions: 3,
        minimumDaysSinceFirstLaunch: 3,
        minimumActivationEvents: 3,
        cooldownDays: 90,
        minimumSessionInterval: 30 * 60
    )

    func isEligible(
        snapshot: ReviewPromptSnapshot,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Bool {
        guard snapshot.sessionCount >= minimumSessions else { return false }
        guard let firstLaunchDate = snapshot.firstLaunchDate else { return false }
        guard days(from: firstLaunchDate, to: now, calendar: calendar) >= minimumDaysSinceFirstLaunch
        else { return false }
        guard snapshot.activationEventCount >= minimumActivationEvents else { return false }

        if let lastPromptAttemptDate = snapshot.lastPromptAttemptDate {
            return days(from: lastPromptAttemptDate, to: now, calendar: calendar) >= cooldownDays
        }

        return true
    }

    private func days(from start: Date, to end: Date, calendar: Calendar) -> Int {
        max(0, calendar.dateComponents([.day], from: start, to: end).day ?? 0)
    }
}

final class ReviewPromptStorage {
    private let defaults: UserDefaults
    private let keyPrefix: String

    init(defaults: UserDefaults = .standard, keyPrefix: String = "reviewPrompt") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    var snapshot: ReviewPromptSnapshot {
        ReviewPromptSnapshot(
            sessionCount: integer(for: "sessionCount"),
            firstLaunchDate: date(for: "firstLaunchDate"),
            activationEventCount: integer(for: "activationEventCount"),
            lastActivationDate: date(for: "lastActivationDate"),
            lastPromptAttemptDate: date(for: "lastPromptAttemptDate")
        )
    }

    func recordSessionStart(now: Date = .now, minimumInterval: TimeInterval) {
        if date(for: "firstLaunchDate") == nil {
            set(now, for: "firstLaunchDate")
        }

        if let lastSessionStartDate = date(for: "lastSessionStartDate"),
            now.timeIntervalSince(lastSessionStartDate) < minimumInterval
        {
            return
        }

        set(integer(for: "sessionCount") + 1, for: "sessionCount")
        set(now, for: "lastSessionStartDate")
    }

    func recordActivationEvent(_ event: ReviewPromptActivationEvent, at date: Date = .now) {
        set(integer(for: "activationEventCount") + 1, for: "activationEventCount")
        set(event.rawValue, for: "lastActivationEvent")
        set(date, for: "lastActivationDate")
    }

    func recordPromptAttempt(at date: Date = .now) {
        set(date, for: "lastPromptAttemptDate")
    }

    func reset() {
        [
            "sessionCount",
            "firstLaunchDate",
            "lastSessionStartDate",
            "activationEventCount",
            "lastActivationEvent",
            "lastActivationDate",
            "lastPromptAttemptDate",
        ].forEach { defaults.removeObject(forKey: key($0)) }
    }

    private func integer(for name: String) -> Int {
        defaults.integer(forKey: key(name))
    }

    private func date(for name: String) -> Date? {
        defaults.object(forKey: key(name)) as? Date
    }

    private func set(_ value: Any, for name: String) {
        defaults.set(value, forKey: key(name))
    }

    private func key(_ name: String) -> String {
        "\(keyPrefix).\(name)"
    }
}

@MainActor
final class ReviewPromptManager {
    static let shared = ReviewPromptManager()

    var rules: ReviewPromptRules

    #if DEBUG
        var debugAlwaysRequestReview = false
    #endif

    private let storage: ReviewPromptStorage

    init(
        storage: ReviewPromptStorage? = nil,
        rules: ReviewPromptRules? = nil
    ) {
        self.storage = storage ?? ReviewPromptStorage()
        self.rules = rules ?? .echoDefault
    }

    func recordSessionStart(now: Date = .now) {
        storage.recordSessionStart(now: now, minimumInterval: rules.minimumSessionInterval)
    }

    func recordActivationEvent(_ event: ReviewPromptActivationEvent, now: Date = .now) {
        storage.recordActivationEvent(event, at: now)
        requestReviewIfAppropriate(now: now)
    }

    func shouldRequestReview(now: Date = .now, calendar: Calendar = .current) -> Bool {
        #if DEBUG
            if debugAlwaysRequestReview { return true }
        #endif

        return rules.isEligible(snapshot: storage.snapshot, now: now, calendar: calendar)
    }

    func requestReviewIfAppropriate(now: Date = .now) {
        guard shouldRequestReview(now: now) else { return }
        guard requestReview() else { return }
        storage.recordPromptAttempt(at: now)
    }

    func resetTracking() {
        storage.reset()
    }

    private func requestReview() -> Bool {
        #if os(iOS)
            guard let scene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
            else { return false }

            AppStore.requestReview(in: scene)
            return true
        #else
            return false
        #endif
    }
}
