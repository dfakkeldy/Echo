// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct PlayerDeepLink: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case play(time: TimeInterval?)
        case focus
        case read
        case study
        // MARK: Navigation destinations
        case navigateToSettings
        case navigateToAppearance
        case navigateToAudioSettings
        case navigateToChapter(Int)
        case navigateToBookmark(UUID)
    }

    let action: Action

    init?(url: URL) {
        guard url.scheme == "echoaudio" else {
            return nil
        }

        switch url.host {
        case "play":
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let time = components?.queryItems?
                .first(where: { $0.name == "time" })
                .flatMap { $0.value }
                .flatMap(TimeInterval.init)
            self.action = .play(time: time)
        case "focus":
            self.action = .focus
        case "read":
            self.action = .read
        case "study":
            self.action = .study
        default:
            // Path-based URL parsing for navigation destinations.
            // URL format: echoaudio://<host>/settings[/appearance|/audio]
            //             echoaudio://<host>/chapter/<index>
            //             echoaudio://<host>/bookmark/<uuid>
            let components = url.pathComponents.filter { $0 != "/" }
            if components.first == "settings" {
                if components.count > 1 {
                    switch components[1] {
                    case "appearance": self.action = .navigateToAppearance
                    case "audio": self.action = .navigateToAudioSettings
                    default: self.action = .navigateToSettings
                    }
                } else {
                    self.action = .navigateToSettings
                }
            } else if components.first == "chapter", components.count > 1,
                let index = Int(components[1])
            {
                self.action = .navigateToChapter(index)
            } else if components.first == "bookmark", components.count > 1,
                let uuid = UUID(uuidString: components[1])
            {
                self.action = .navigateToBookmark(uuid)
            } else {
                return nil
            }
        }
    }
}
