#if !os(watchOS)
import AppIntents
import SwiftUI
import WidgetKit

struct Echo_WidgetControl: ControlWidget {
    static let kind: String = "Dan.EchoAudiobooks.watchkitapp.Echo_Widget"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: TogglePlaybackIntent()) {
                let defaults = AppGroupDefaults.shared
                let isPlaying = defaults.bool(forKey: "isPlaying")
                Label(isPlaying ? String(localized: "Pause") : String(localized: "Play"), systemImage: isPlaying ? "pause.fill" : "play.fill")
            }
        }
        .displayName("Echo Playback")
        .description("Toggle audiobook playback.")
    }
}
#endif

