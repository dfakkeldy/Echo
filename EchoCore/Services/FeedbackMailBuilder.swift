// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum FeedbackMailBuilder {
    static let defaultRecipient = "echo@kinnokilabs.com"

    static func mailtoURL(
        for entry: FeedbackEntry,
        recipient: String = defaultRecipient
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = recipient
        components.queryItems = [
            URLQueryItem(name: "subject", value: entry.emailSubject),
            URLQueryItem(name: "body", value: entry.emailBody),
        ]
        return components.url
    }
}
