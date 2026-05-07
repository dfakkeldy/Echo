import AppIntents
import SwiftUI
import WidgetKit

struct AuDioHD_WidgetControl: ControlWidget {
    static let kind: String = "Dan.AuDioHD.watchkitapp.AuDioHD Widget"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: TogglePlaybackIntent()) {
                let defaults = UserDefaults(suiteName: "group.com.bookloop")
                let isPlaying = defaults?.bool(forKey: "isPlaying") ?? false
                Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
            }
        }
        .displayName("AuDioHD Playback")
        .description("Toggle audiobook playback.")
    }
}
