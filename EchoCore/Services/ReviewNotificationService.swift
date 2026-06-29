// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import UserNotifications
import os.log

enum ReviewNotificationAuthorizationStatus: Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
    case unknown

    var canScheduleNotifications: Bool {
        self == .authorized || self == .provisional
    }
}

struct ReviewNotificationScheduleRequest: Sendable, Equatable {
    let identifier: String
    let title: String
    let body: String
    let badge: Int
    let triggerDateComponents: DateComponents
    let repeats: Bool

    var triggerHour: Int? { triggerDateComponents.hour }
    var triggerMinute: Int? { triggerDateComponents.minute }
}

@MainActor
protocol ReviewNotificationScheduling {
    func authorizationStatus() async -> ReviewNotificationAuthorizationStatus
    func add(_ request: ReviewNotificationScheduleRequest) async throws
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async
}

private struct UserNotificationScheduler: ReviewNotificationScheduling {
    func authorizationStatus() async -> ReviewNotificationAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            .reviewNotificationStatus
    }

    func add(_ request: ReviewNotificationScheduleRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        content.badge = NSNumber(value: request.badge)

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: request.triggerDateComponents,
            repeats: request.repeats
        )
        try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: request.identifier,
                content: content,
                trigger: trigger
            )
        )
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}

/// Schedules a daily local notification when the user has due flashcard reviews.
///
/// `nonisolated`: a stateless service. The fire-and-forget entry points keep their
/// synchronous signatures (callers don't `await`) but do their work inside a `Task`
/// using the `async` UserNotifications APIs instead of completion handlers — that
/// avoids the Swift-6 `@Sendable`-closure captures of `center`/`logger`/`identifier`.
nonisolated enum ReviewNotificationService {
    private static let logger = Logger(category: "ReviewNotifications")
    static let notificationIdentifier = "com.echo.audiobooks.dailyReview"

    /// Updates (or removes) the daily review notification based on current due count.
    /// Call this after grading a card or loading the review queue.
    static func updateNotification(dueCount: Int, isEnabled: Bool) {
        Task {
            await updateNotification(
                dueCount: dueCount,
                isEnabled: isEnabled,
                scheduler: UserNotificationScheduler()
            )
        }
    }

    static func removeScheduledNotification() {
        Task {
            await UserNotificationScheduler()
                .removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
        }
    }

    @MainActor
    static func updateNotification(
        dueCount: Int,
        isEnabled: Bool,
        scheduler: ReviewNotificationScheduling,
        now: Date = .now,
        calendar: Calendar = .current
    ) async {
        guard isEnabled else {
            await scheduler.removePendingNotificationRequests(
                withIdentifiers: [notificationIdentifier])
            return
        }

        guard dueCount > 0 else {
            await scheduler.removePendingNotificationRequests(
                withIdentifiers: [notificationIdentifier])
            return
        }

        guard await scheduler.authorizationStatus().canScheduleNotifications else { return }

        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = 9
        components.minute = 0
        guard let fireDate = calendar.date(from: components) else { return }
        let triggerDate = fireDate > now ? fireDate : now.addingTimeInterval(60)
        let triggerDateComponents = calendar.dateComponents(
            [.hour, .minute],
            from: triggerDate
        )

        let request = ReviewNotificationScheduleRequest(
            identifier: notificationIdentifier,
            title: String(localized: "Flashcards Due"),
            body: String(
                localized: "You have ^[\(dueCount) flashcard](inflect: true) to review today."),
            badge: dueCount,
            triggerDateComponents: triggerDateComponents,
            repeats: false
        )
        do {
            try await scheduler.add(request)
        } catch {
            logger.error("Failed to schedule review notification: \(error.localizedDescription)")
        }
    }

    /// Requests notification authorization from the user.
    static func requestAuthorization() async -> ReviewNotificationAuthorizationStatus {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            logger.info("Notification authorization \(granted ? "granted" : "denied")")
            return await UserNotificationScheduler().authorizationStatus()
        } catch {
            logger.error("Notification authorization error: \(error.localizedDescription)")
            return .unknown
        }
    }
}

private extension UNAuthorizationStatus {
    var reviewNotificationStatus: ReviewNotificationAuthorizationStatus {
        switch self {
        case .notDetermined:
            .notDetermined
        case .denied:
            .denied
        case .authorized:
            .authorized
        case .provisional:
            .provisional
#if os(iOS)
        case .ephemeral:
            .ephemeral
#endif
        @unknown default:
            .unknown
        }
    }
}
