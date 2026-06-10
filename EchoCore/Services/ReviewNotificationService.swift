import Foundation
import UserNotifications
import os.log

/// Schedules a daily local notification when the user has due flashcard reviews.
enum ReviewNotificationService {
    private static let logger = Logger(category: "ReviewNotifications")
    private static let identifier = "com.echo.audiobooks.dailyReview"

    /// Updates (or removes) the daily review notification based on current due count.
    /// Call this after grading a card or loading the review queue.
    static func updateNotification(dueCount: Int) {
        let center = UNUserNotificationCenter.current()

        guard dueCount > 0 else {
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            return
        }

        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized ||
                  settings.authorizationStatus == .provisional else { return }

            let content = UNMutableNotificationContent()
            content.title = String(localized: "Flashcards Due")
            content.body = String(localized: "You have ^[\(dueCount) flashcard](inflect: true) to review today.")
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

            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
            center.add(request) { error in
                if let error {
                    logger.error("Failed to schedule review notification: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Requests notification authorization from the user.
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                logger.error("Notification authorization error: \(error.localizedDescription)")
            }
            logger.info("Notification authorization \(granted ? "granted" : "denied")")
        }
    }
}
