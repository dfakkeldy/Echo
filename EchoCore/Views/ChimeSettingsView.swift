import SwiftUI

struct ChimeSettingsView: View {
    @Environment(SettingsManager.self) private var settings
    let engine: (any ChimeScheduling)?

    var chimeSound: ChimeSound {
        ChimeSound(rawValue: settings.chimeSound) ?? .softChime
    }

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Interval") {
                Picker("Chime every", selection: $settings.chimeInterval) {
                    Text("Off").tag(0.0)
                    Text("15 minutes").tag(900.0)
                    Text("30 minutes").tag(1800.0)
                    Text("60 minutes").tag(3600.0)
                }
            }
            Section("Sound") {
                ForEach(ChimeSound.allCases) { sound in
                    HStack {
                        Image(systemName: sound.sfSymbol)
                        Text(sound.displayName)
                        Spacer()
                        if sound == chimeSound { Image(systemName: "checkmark") }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        settings.chimeSound = sound.rawValue
                        // Preview: play once
                        engine?.cancel()
                        engine?.schedule(interval: 0.1, sound: sound)
                    }
                }
            }
            Section("Volume") {
                HStack {
                    Image(systemName: "speaker")
                    Slider(value: $settings.chimeVolume)
                }
            }
        }
        .onChange(of: settings.chimeInterval) { apply() }
        .onChange(of: settings.chimeSound) { apply() }
        .onChange(of: settings.chimeVolume) { apply() }
    }

    private func apply() {
        engine?.cancel()
        if settings.chimeInterval > 0 {
            let sound = ChimeSound(rawValue: settings.chimeSound) ?? .softChime
            engine?.schedule(interval: settings.chimeInterval, sound: sound)
        }
    }
}
