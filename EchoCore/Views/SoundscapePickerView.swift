import SwiftUI

// NOTE: File-based ambient presets (rain, cafe, forest, ocean, fireplace) require
// CC0-licensed audio loops bundled in the app target with the matching file names
// ("rain_loop.caf", "cafe_loop.wav", etc.). The DefaultSoundscapeMixer searches
// Bundle.main for common audio extensions (caf, wav, aiff, mp3, m4a, aac) and
// logs an error if the file is not found — playback continues silently.
// Generative presets (white noise, brown noise, binaural beats) work immediately
// without any audio files.
//
// Recommended source: freesound.org (filter by CC0 license).
// File format: mono or stereo, 44.1 kHz, CAF or WAV for best compatibility.
// Preserve the loop point — files should be seamless loop-ready audio clips.

struct SoundscapePickerView: View {
    @State private var selectedPreset: SoundscapePreset?
    @Environment(SettingsManager.self) private var settings
    @Environment(\.dismiss) var dismiss
    let engine: (any SoundscapePlaying)?

    let naturePresets: [SoundscapePreset] = [
        SoundscapePreset(id: "rain", name: "Rain", sfSymbol: "cloud.rain", category: .nature, fileName: "rain_loop", generatorConfig: nil),
        SoundscapePreset(id: "cafe", name: "Cafe", sfSymbol: "cup.and.saucer", category: .urban, fileName: "cafe_loop", generatorConfig: nil),
        SoundscapePreset(id: "forest", name: "Forest", sfSymbol: "leaf", category: .nature, fileName: "forest_loop", generatorConfig: nil),
        SoundscapePreset(id: "ocean", name: "Ocean", sfSymbol: "water.waves", category: .nature, fileName: "ocean_loop", generatorConfig: nil),
        SoundscapePreset(id: "fireplace", name: "Fireplace", sfSymbol: "flame", category: .nature, fileName: "fireplace_loop", generatorConfig: nil),
        SoundscapePreset(id: "white_noise", name: "White Noise", sfSymbol: "waveform", category: .tonal, fileName: nil, generatorConfig: SoundscapePreset.GeneratorConfig(type: .whiteNoise, carrierFrequency: nil, beatFrequency: nil, pulseRate: nil)),
        SoundscapePreset(id: "brown_noise", name: "Brown Noise", sfSymbol: "waveform.circle", category: .tonal, fileName: nil, generatorConfig: SoundscapePreset.GeneratorConfig(type: .brownNoise, carrierFrequency: nil, beatFrequency: nil, pulseRate: nil)),
        SoundscapePreset(id: "binaural", name: "Binaural Beats", sfSymbol: "ear", category: .tonal, fileName: nil, generatorConfig: SoundscapePreset.GeneratorConfig(type: .binauralBeats, carrierFrequency: 200, beatFrequency: 10, pulseRate: nil)),
    ]

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            List {
                Section("Ambient") {
                    ForEach(naturePresets.filter { $0.fileName != nil }) { preset in
                        presetRow(preset)
                    }
                }
                Section("Generative") {
                    ForEach(naturePresets.filter { $0.generatorConfig != nil }) { preset in
                        presetRow(preset)
                    }
                }
                Section("Volume") {
                    HStack {
                        Image(systemName: "speaker.fill")
                        Slider(value: $settings.soundscapeVolume)
                        Image(systemName: "speaker.wave.3.fill")
                    }
                }
            }
            .navigationTitle("Soundscape")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Off") {
                        engine?.stop()
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func presetRow(_ preset: SoundscapePreset) -> some View {
        HStack {
            Image(systemName: preset.sfSymbol)
            Text(preset.name)
            Spacer()
            if selectedPreset?.id == preset.id {
                Image(systemName: "checkmark").foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedPreset = preset
            engine?.volume = settings.soundscapeVolume
            Task { await engine?.play(preset: preset) }
        }
    }
}
