import WidgetKit
import AppIntents
import WatchConnectivity

enum AppGroupDefaults {
    static let suiteName = "group.com.orbitaudiobooks"

    static var shared: UserDefaults {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            #if DEBUG
            assertionFailure("Unable to open app-group UserDefaults suite: \(suiteName)")
            #endif
            return .standard
        }
        return defaults
    }
    
    static var isHapticFeedbackEnabled: Bool {
        get { shared.object(forKey: "isHapticFeedbackEnabled") as? Bool ?? true }
        set { shared.set(newValue, forKey: "isHapticFeedbackEnabled") }
    }
}

class SessionDelegator: NSObject, WCSessionDelegate {
    var continuation: CheckedContinuation<Void, Never>?
    private(set) var activationState: WCSessionActivationState = .notActivated

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        self.activationState = activationState
        continuation?.resume()
        continuation = nil
    }
}

struct TogglePlaybackIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Playback"
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        // Toggle playback via WCSession
        if WCSession.isSupported() {
            let session = WCSession.default
            
            let delegator = SessionDelegator()
            session.delegate = delegator
            
            if session.activationState != .activated {
                session.activate()
                await withCheckedContinuation { continuation in
                    delegator.continuation = continuation
                }
            }

            guard session.activationState == .activated || delegator.activationState == .activated else {
                let defaults = AppGroupDefaults.shared
                let currentIsPlaying = defaults.bool(forKey: "isPlaying")
                defaults.set(!currentIsPlaying, forKey: "isPlaying")
                WidgetCenter.shared.reloadTimelines(ofKind: "Orbit_Audiobooks_Widget")
                return .result()
            }
            
            let message = ["command": "toggle", "timestamp": Date().timeIntervalSince1970] as [String : Any]
            
            if session.isReachable {
                await withCheckedContinuation { continuation in
                    session.sendMessage(message) { _ in
                        continuation.resume()
                    } errorHandler: { _ in
                        continuation.resume()
                    }
                }
            } else {
                // Use transferUserInfo which is queued by the OS and sent even if the extension suspends!
                session.transferUserInfo(message)
                
                // Wait briefly to allow the WCSession daemon to pick up the transfer
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        
        // Optimistically toggle state in UserDefaults for immediate UI update
        let defaults = AppGroupDefaults.shared
        let currentIsPlaying = defaults.bool(forKey: "isPlaying")
        defaults.set(!currentIsPlaying, forKey: "isPlaying")
        WidgetCenter.shared.reloadTimelines(ofKind: "Orbit_Audiobooks_Widget")
        
        return .result()
    }
}

struct CreateBookmarkIntent: AppIntent {
    static var title: LocalizedStringResource = "Create Bookmark"
    static var description = IntentDescription("Creates a new bookmark for the current audiobook position.")
    
    @Parameter(title: "Note")
    var note: String?

    func perform() async throws -> some IntentResult {
        let defaults = AppGroupDefaults.shared
        
        guard let folderKey = defaults.string(forKey: "folderKey"),
              let trackId = defaults.string(forKey: "trackId"),
              let currentTime = defaults.object(forKey: "currentTime") as? TimeInterval else {
            throw NSError(domain: "CreateBookmarkIntent", code: 1, userInfo: [NSLocalizedDescriptionKey: "No active audiobook found."])
        }

        let newBookmark = Bookmark(
            id: UUID(),
            title: "Bookmark \(Date().formatted(date: .omitted, time: .shortened))",
            folderKey: folderKey,
            trackId: trackId,
            timestamp: currentTime,
            note: note
        )

        let bookmarksKey = "bookmarks_\(folderKey)"
        var bookmarks = (try? JSONDecoder().decode([Bookmark].self, from: defaults.data(forKey: bookmarksKey) ?? Data())) ?? []
        bookmarks.append(newBookmark)
        
        if let data = try? JSONEncoder().encode(bookmarks) {
            defaults.set(data, forKey: bookmarksKey)
        }

        return .result()
    }
}

struct BookmarkAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateBookmarkIntent(),
            phrases: [
                "Bookmark this in \(.applicationName)"
            ],
            shortTitle: "Create Bookmark",
            systemImageName: "bookmark"
        )
    }
}
