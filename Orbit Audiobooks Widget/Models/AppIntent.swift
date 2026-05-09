import WidgetKit
import AppIntents
import WatchConnectivity

class SessionDelegator: NSObject, WCSessionDelegate {
    var continuation: CheckedContinuation<Void, Never>?
    
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
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
            if session.delegate == nil {
                session.delegate = delegator
            }
            
            if session.activationState != .activated {
                session.activate()
                await withCheckedContinuation { continuation in
                    delegator.continuation = continuation
                }
            }
            
            _ = delegator
            
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
        let defaults = UserDefaults(suiteName: "group.com.audiohd")
        let currentIsPlaying = defaults?.bool(forKey: "isPlaying") ?? false
        defaults?.set(!currentIsPlaying, forKey: "isPlaying")
        WidgetCenter.shared.reloadAllTimelines()
        
        return .result()
    }
}
