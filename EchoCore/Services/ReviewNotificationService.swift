// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import UserNotifications
import os.log

/// Schedules a daily local notification when the user has due flashcard reviews.
///
/// `nonisolated`: a stateless service. The fire-and-forget entry points keep their
/// synchronous signatures (callers don't `await`) but do their work inside a `Task`
/// using the `async` UserNotifications APIs instead of completion handlers — that
/// avoids the Swift-6 `@Sendable`-closure captures of `center`/`logger`/`identifier`.
nonisolated enum ReviewNotificationService {
    private static let logger = Logger(category: "ReviewNotifications")
    private static let identifier = "com.echo.audiobooks.dailyReview"

    /// Updates (or removes) the daily review notification based on current due count.
    /// Call this after grading a card or loading the review queue.
    static func updateNotification(dueCount: Int) {
        Task { await updateNotificationAsync(dueCount: dueCount) }
    }

    private static func updateNotificationAsync(dueCount: Int) async {
        let center = UNUserNotificationCenter.current()

        guard dueCount > 0 else {
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            return
        }

        let settings = await center.notificationSettings()
        guard
            settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
        else { return }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Flashcards Due")
        content.body = String(
            localized: "You have ^[\(dueCount) flashcard](inflect: true) to review today.")
        content.sound = .default
        content.badge = NSNumber(value: dueCount)

        // Fire at 9 AM. If already past, fire in 60 seconds as a fallback.
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = 9
        components.minute = 0
        guard let fireDate = Calendar.current.date(from: components) else { return }
        let triggerDate = fireDate > Date() ? fireDate : Date().addingTimeInterval(60)
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents([.hour, .minute], from: triggerDate),
            repeats: false
        )

        let request = UNNotificationRequest(
            identifier: identifier, content: content, trigger: trigger)
        do {
            try await center.add(request)
        } catch {
            logger.error("Failed to schedule review notification: \(error.localizedDescription)")
        }
    }

    /// Requests notification authorization from the user.
    static func requestAuthorization() {
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge])
                logger.info("Notification authorization \(granted ? "granted" : "denied")")
            } catch {
                logger.error("Notification authorization error: \(error.localizedDescription)")
            }
        }
    }
}
