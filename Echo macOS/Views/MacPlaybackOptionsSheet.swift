// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Compact playback-options surface for macOS, presented as a popover anchored
/// to the player bar's options button. Mirrors the iOS PlaybackOptionsSheet:
/// playback speed, a 3-way loop mode (Off / Chapter / Bookmark), the
/// configurable skip interval, and a Volume Boost toggle. Full Smart Rewind
/// configuration lives in the macOS Settings scene (WS-J), reached via the
/// "Smart Rewind…" row.
///
/// Named `MacPlaybackOptionsSheet` to match the cross-platform symbol contract,
/// even though it renders inside a `.popover` rather than a modal sheet.
struct MacPlaybackOptionsSheet: View {
    @Environment(MacPlayerModel.self) private var player

    /// Speed presets shared with iOS (SettingsManager.speedPresets parity).
    private let speedPresets: [Float] = [1.0, 1.25, 1.5, 2.0, 3.0]
    /// Skip-interval choices, in seconds.
    private let skipChoices: [Int] = [5, 10, 15, 30, 45, 60, 90]

    var body: some View {
        @Bindable var player = player

        Form {
            Section("Speed") {
                Picker("Playback Speed", selection: $player.playbackRate) {
                    ForEach(speedPresets, id: \.self) { rate in
                        Text(Self.speedLabel(rate)).tag(rate)
                    }
                }
                .pickerStyle(.menu)
            }

            Section {
                Picker("Loop Mode", selection: loopSelection) {
                    Text("Off").tag(LoopMode.off)
                    Text("Chapter").tag(LoopMode.chapter)
                    Text("Bookmark")
                        .tag(LoopMode.bookmark)
                        .disabled(bookmarkLoopUnavailable)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } header: {
                Text("Loop")
            } footer: {
                if bookmarkLoopUnavailable {
                    Text("Add at least two enabled bookmarks to use bookmark looping.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Skip") {
                Picker("Skip Interval", selection: $player.skipInterval) {
                    ForEach(skipChoices, id: \.self) { secs in
                        Text("\(secs)s").tag(secs)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Audio") {
                Toggle("Volume Boost", isOn: $player.isVolumeBoostEnabled)
            }

            Section {
                SettingsLink {
                    Label("Smart Rewind…", systemImage: "gear")
                }
                .buttonStyle(.link)
            } footer: {
                Text("Configure Smart Rewind and more in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 280)
        .padding(.vertical, 4)
    }

    /// Routes loop selection through a demotion guard: choosing `.bookmark` without
    /// a loopable bookmark segment falls back to `.off`, mirroring the iOS
    /// `PlaybackOptionsSheet` so the offered option never silently does nothing.
    private var loopSelection: Binding<LoopMode> {
        Binding(
            get: { player.loopMode },
            set: { newMode in
                if newMode == .bookmark && bookmarkLoopUnavailable {
                    player.loopMode = .off
                } else {
                    player.loopMode = newMode
                }
            }
        )
    }

    private var bookmarkLoopUnavailable: Bool {
        !player.canBookmarkLoop
    }

    /// Speed label formatter — "1×", "1.25×", "1.5×".
    static func speedLabel(_ rate: Float) -> String {
        if rate == rate.rounded() {
            return "\(Int(rate))×"
        }
        return rate.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}
