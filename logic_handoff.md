# Logic Handoff — Watch sync and slot state

## WatchAction enum

```swift
enum WatchAction: String, Codable, CaseIterable, Identifiable {
    case playPause
    case skipForward
    case skipBackward
    case nextTrack
    case previousTrack
    case loopMode
    case speed
    case sleepTimer
    case bookmark
    case empty

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .playPause: return "playpause.fill"
        case .skipForward: return "goforward.30"
        case .skipBackward: return "gobackward.30"
        case .nextTrack: return "forward.end.fill"
        case .previousTrack: return "backward.end.fill"
        case .loopMode: return "infinity"
        case .speed: return "gauge.medium"
        case .sleepTimer: return "moon.zzz.fill"
        case .bookmark: return "bookmark.fill"
        case .empty: return "plus"
        }
    }
}
```

## State management for button arrays (iOS designer + Watch)

```swift
// iOS designer — persistent storage + UI state
@AppStorage("watchPage1") private var page1Raw: String = "empty,empty,skipBackward,playPause,skipForward"
@AppStorage("watchPage2") private var page2Raw: String = "loopMode,empty,speed,sleepTimer,bookmark"

@State private var page1Slots: [WatchAction] = []
@State private var page2Slots: [WatchAction] = []
@State private var selectedPage: Int = 0

private func loadSlots() {
    page1Slots = page1Raw.split(separator: ",").compactMap { WatchAction(rawValue: String($0)) }
    while page1Slots.count < 5 { page1Slots.append(.empty) }

    page2Slots = page2Raw.split(separator: ",").compactMap { WatchAction(rawValue: String($0)) }
    while page2Slots.count < 5 { page2Slots.append(.empty) }
}

private func saveSlots() {
    page1Raw = page1Slots.map { $0.rawValue }.joined(separator: ",")
    page2Raw = page2Slots.map { $0.rawValue }.joined(separator: ",")
    model.syncToWatch() // push updated layout to watch
}

private func handleDrop(providers: [NSItemProvider], page: Int, index: Int) -> Bool {
    guard let provider = providers.first else { return false }
    provider.loadObject(ofClass: NSString.self) { string, error in
        if let rawValue = string as? String, let action = WatchAction(rawValue: rawValue) {
            DispatchQueue.main.async {
                if page == 0 {
                    page1Slots[index] = action
                } else {
                    page2Slots[index] = action
                }
            }
        }
    }
    return true
}
```

```swift
// Watch-side state (simple example used by WatchViewModel)
var page1Slots: [WatchAction] = [.skipBackward, .playPause, .skipForward]
var page2Slots: [WatchAction] = [.loopMode, .speed, .sleepTimer, .bookmark]
```

## WCSession sync functions (iOS -> Watch and Watch handlers)

```swift
// iOS side: setup + sync
private func setupWatchConnectivity() {
    if WCSession.isSupported() {
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }
}

func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
    handleMessage(message)
}

func session(_ session: WCSession, didReceiveMessage message: [String : Any], replyHandler: @escaping ([String : Any]) -> Void) {
    handleMessage(message)
    replyHandler(["status": "ok"])
}

func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any] = [:]) {
    handleMessage(userInfo)
}

func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
    DispatchQueue.main.async {
        if let command = applicationContext["command"] as? String {
            if command == "toggle" {
                self.togglePlayPause()
            }
        }
    }
}

func syncToWatch() {
    guard WCSession.default.activationState == .activated else { return }

    var context: [String: Any] = [:]
    context["isPlaying"] = isPlaying
    context["progressFraction"] = progressFraction

    let title = chapters.count >= 2 ? (currentSubtitle.isEmpty ? "Chapter \((currentChapterIndex ?? 0) + 1)" : currentSubtitle) : currentTitle
    context["title"] = title

    let crownAction = UserDefaults.standard.string(forKey: "crownAction") ?? "volume"
    context["crownAction"] = crownAction
    context["loopModeOn"] = loopModeOn

    context["watchPage1"] = UserDefaults.standard.string(forKey: "watchPage1") ?? "skipBackward,playPause,skipForward"
    context["watchPage2"] = UserDefaults.standard.string(forKey: "watchPage2") ?? "loopMode,speed,sleepTimer,bookmark"

    if let data = watchThumbnailData {
        context["thumbnailData"] = data
    }

    do {
        try WCSession.default.updateApplicationContext(context)
    } catch {
        print("Failed to sync to watch: \(error)")
    }
}
```

```swift
// Watch-side: receive application context and update local state
func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
    DispatchQueue.main.async {
        let defaults = UserDefaults(suiteName: "group.com.bookloop")
        if let crownAction = applicationContext["crownAction"] as? String {
            defaults?.set(crownAction, forKey: "crownAction")
        }
        if let isPlaying = applicationContext["isPlaying"] as? Bool {
            self.isPlaying = isPlaying
            defaults?.set(isPlaying, forKey: "isPlaying")
        }
        if let title = applicationContext["title"] as? String {
            self.title = title
            defaults?.set(title, forKey: "title")
        }
        if let progressFraction = applicationContext["progressFraction"] as? Double {
            self.progressFraction = progressFraction
            defaults?.set(progressFraction, forKey: "progressFraction")
        }
        if let loopModeOn = applicationContext["loopModeOn"] as? Bool {
            self.loopModeOn = loopModeOn
            defaults?.set(loopModeOn, forKey: "loopModeOn")
        }
        if let watchPage1 = applicationContext["watchPage1"] as? String {
            self.page1Slots = watchPage1.split(separator: ",").compactMap { WatchAction(rawValue: String($0)) }
            defaults?.set(watchPage1, forKey: "watchPage1")
        }
        if let watchPage2 = applicationContext["watchPage2"] as? String {
            self.page2Slots = watchPage2.split(separator: ",").compactMap { WatchAction(rawValue: String($0)) }
            defaults?.set(watchPage2, forKey: "watchPage2")
        }
        if let thumbnailData = applicationContext["thumbnailData"] as? Data {
            defaults?.set(thumbnailData, forKey: "thumbnailData")
            if let image = UIImage(data: thumbnailData) {
                self.thumbnailImage = image
            }
        } else {
            defaults?.removeObject(forKey: "thumbnailData")
            self.thumbnailImage = nil
        }
        WidgetCenter.shared.reloadAllTimelines()
        self.onUpdateReceived?()
        WKInterfaceDevice.current().play(.success)
    }
}
```

```swift
// Watch-side: send a command back to phone (message)
func sendCommand(_ command: String, params: [String: Any]? = nil) {
    if WCSession.default.isReachable {
        var message: [String: Any] = ["command": command]
        if let params = params {
            for (key, value) in params {
                message[key] = value
            }
        }
        WCSession.default.sendMessage(message, replyHandler: nil, errorHandler: { error in
            print("Error sending command: \(error)")
        })
    }

    // Optional haptic on local device when sending certain commands
    switch command {
    case "play", "pause", "toggle":
        WKInterfaceDevice.current().play(.click)
    case "next", "skipForward":
        WKInterfaceDevice.current().play(.directionUp)
    case "skipBackward", "previous":
        WKInterfaceDevice.current().play(.directionDown)
    default:
        break
    }
}