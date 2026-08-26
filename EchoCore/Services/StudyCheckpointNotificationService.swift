// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS)
import Foundation
import UserNotifications

@MainActor
final class StudyCheckpointNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let categoryIdentifier = "STUDY_CHECKPOINT"
    static let goodActionIdentifier = "GOOD"
    static let againActionIdentifier = "AGAIN"
    static let notificationIdentifier = "com.echo.audiobooks.studyCheckpoint"

    var onAction: ((StudyCheckpointCoordinator.CheckpointAction) -> Void)?

    private var didActivate = false

    func activate() {
        guard !didActivate else { return }
        didActivate = true

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let good = UNNotificationAction(
            identifier: Self.goodActionIdentifier,
            title: String(localized: "Good"),
            options: []
        )
        let again = UNNotificationAction(
            identifier: Self.againActionIdentifier,
            title: String(localized: "Again"),
            options: []
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoryIdentifier,
                actions: [good, again],
                intentIdentifiers: [],
                options: []
            )
        ])
    }

    func postCheckpoint(chapterTitle: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Chapter finished")
        content.body = String(localized: "How did \"\(chapterTitle)\" go?")
        content.categoryIdentifier = Self.categoryIdentifier

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: Self.notificationIdentifier,
                content: content,
                trigger: nil
            ))
    }

    func removeCheckpoint() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.notificationIdentifier])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let actionID = response.actionIdentifier
        await MainActor.run {
            switch actionID {
            case Self.goodActionIdentifier:
                onAction?(.good)
            case Self.againActionIdentifier:
                onAction?(.again)
            default:
                break
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        []
    }
}
#endif
