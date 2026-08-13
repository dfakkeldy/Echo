// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
struct ReviewNotificationServiceTests {
    @Test func updateNotificationRemovesPendingRequestWhenFeatureIsDisabled() async {
        let scheduler = RecordingReviewNotificationScheduler(status: .authorized)

        await ReviewNotificationService.updateNotification(
            dueCount: 3,
            isEnabled: false,
            scheduler: scheduler,
            now: Date(timeIntervalSince1970: 1_800_000),
            calendar: .gregorianUTC
        )

        let snapshot = scheduler.snapshot()
        #expect(snapshot.addedRequests.isEmpty)
        #expect(snapshot.removedIdentifiers == [ReviewNotificationService.notificationIdentifier])
    }

    @Test func updateNotificationDoesNotScheduleWhenNotificationsAreNotAuthorized() async {
        let scheduler = RecordingReviewNotificationScheduler(status: .denied)

        await ReviewNotificationService.updateNotification(
            dueCount: 3,
            isEnabled: true,
            scheduler: scheduler,
            now: Date(timeIntervalSince1970: 1_800_000),
            calendar: .gregorianUTC
        )

        let snapshot = scheduler.snapshot()
        #expect(snapshot.addedRequests.isEmpty)
        #expect(snapshot.removedIdentifiers.isEmpty)
    }

    @Test func updateNotificationSchedulesWhenNotificationsAreAuthorized() async {
        let scheduler = RecordingReviewNotificationScheduler(status: .authorized)

        await ReviewNotificationService.updateNotification(
            dueCount: 4,
            isEnabled: true,
            scheduler: scheduler,
            now: Date(timeIntervalSince1970: 0),
            calendar: .gregorianUTC
        )

        let snapshot = scheduler.snapshot()
        #expect(snapshot.addedRequests.count == 1)
        #expect(snapshot.addedRequests.first?.identifier == ReviewNotificationService.notificationIdentifier)
        #expect(snapshot.addedRequests.first?.badge == 4)
        #expect(snapshot.addedRequests.first?.triggerHour == 9)
        #expect(snapshot.removedIdentifiers.isEmpty)
    }

    @Test func updateNotificationRemovesPendingRequestWhenNoReviewsAreDue() async {
        let scheduler = RecordingReviewNotificationScheduler(status: .authorized)

        await ReviewNotificationService.updateNotification(
            dueCount: 0,
            isEnabled: true,
            scheduler: scheduler,
            now: Date(timeIntervalSince1970: 1_800_000),
            calendar: .gregorianUTC
        )

        let snapshot = scheduler.snapshot()
        #expect(snapshot.addedRequests.isEmpty)
        #expect(snapshot.removedIdentifiers == [ReviewNotificationService.notificationIdentifier])
    }
}

@MainActor
private final class RecordingReviewNotificationScheduler: ReviewNotificationScheduling {
    private let status: ReviewNotificationAuthorizationStatus
    private var addedRequests: [ReviewNotificationScheduleRequest] = []
    private var removedIdentifiers: [String] = []

    init(status: ReviewNotificationAuthorizationStatus) {
        self.status = status
    }

    func authorizationStatus() async -> ReviewNotificationAuthorizationStatus {
        status
    }

    func add(_ request: ReviewNotificationScheduleRequest) async throws {
        addedRequests.append(request)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async {
        removedIdentifiers.append(contentsOf: identifiers)
    }

    func snapshot() -> Snapshot {
        Snapshot(addedRequests: addedRequests, removedIdentifiers: removedIdentifiers)
    }

    struct Snapshot {
        let addedRequests: [ReviewNotificationScheduleRequest]
        let removedIdentifiers: [String]
    }
}

private extension Calendar {
    static var gregorianUTC: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }
}
