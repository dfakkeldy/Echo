// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct ReviewPromptManagerTests {
    @Test func rulesRequireActivationEventsBeforePrompting() {
        let now = Date(timeIntervalSince1970: 1_800_000)
        let rules = ReviewPromptRules(
            minimumSessions: 2,
            minimumDaysSinceFirstLaunch: 1,
            minimumActivationEvents: 2,
            cooldownDays: 60,
            minimumSessionInterval: 0
        )
        var snapshot = ReviewPromptSnapshot(
            sessionCount: 2,
            firstLaunchDate: now.addingTimeInterval(-2 * 86_400),
            activationEventCount: 1,
            lastActivationDate: now,
            lastPromptAttemptDate: nil
        )

        #expect(!rules.isEligible(snapshot: snapshot, now: now, calendar: .gregorianUTC))

        snapshot.activationEventCount = 2
        #expect(rules.isEligible(snapshot: snapshot, now: now, calendar: .gregorianUTC))
    }

    @Test func rulesRespectPromptCooldown() {
        let now = Date(timeIntervalSince1970: 1_800_000)
        let rules = ReviewPromptRules(
            minimumSessions: 1,
            minimumDaysSinceFirstLaunch: 0,
            minimumActivationEvents: 1,
            cooldownDays: 90,
            minimumSessionInterval: 0
        )
        let snapshot = ReviewPromptSnapshot(
            sessionCount: 4,
            firstLaunchDate: now.addingTimeInterval(-10 * 86_400),
            activationEventCount: 5,
            lastActivationDate: now,
            lastPromptAttemptDate: now.addingTimeInterval(-10 * 86_400)
        )

        #expect(!rules.isEligible(snapshot: snapshot, now: now, calendar: .gregorianUTC))
    }

    @Test func storageDeduplicatesSessionStartsInsideMinimumInterval() throws {
        let suiteName = "ReviewPromptManagerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let storage = ReviewPromptStorage(defaults: defaults, keyPrefix: "testReviewPrompt")
        let now = Date(timeIntervalSince1970: 1_800_000)

        storage.recordSessionStart(now: now, minimumInterval: 60)
        storage.recordSessionStart(now: now.addingTimeInterval(10), minimumInterval: 60)
        storage.recordSessionStart(now: now.addingTimeInterval(61), minimumInterval: 60)

        #expect(storage.snapshot.sessionCount == 2)
        #expect(storage.snapshot.firstLaunchDate == now)
    }
}

private extension Calendar {
    static var gregorianUTC: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }
}
