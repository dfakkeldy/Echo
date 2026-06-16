// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct ManualAlignmentSheet: View {
    let folderURL: URL
    @Environment(PlayerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var scrubbedTime: TimeInterval = 0
    @State private var joystickValue: Double = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Text(NowPlayingController.formatTime(scrubbedTime))
                    .font(.system(.largeTitle, design: .monospaced).bold())

                HStack(spacing: 24) {
                    Button {
                        scrubbedTime = max(0, scrubbedTime - 5)
                        model.seek(toSeconds: scrubbedTime)
                    } label: {
                        Image(systemName: "gobackward.5")
                            .font(.title)
                    }
                    .accessibilityLabel(Text("Go back 5 seconds"))

                    Button {
                        model.togglePlayPause()
                    } label: {
                        Image(
                            systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill"
                        )
                        .font(.system(size: 64))
                    }
                    .accessibilityLabel(model.isPlaying ? Text("Pause") : Text("Play"))

                    Button {
                        scrubbedTime = min(model.durationSeconds ?? .infinity, scrubbedTime + 5)
                        model.seek(toSeconds: scrubbedTime)
                    } label: {
                        Image(systemName: "goforward.5")
                            .font(.title)
                    }
                    .accessibilityLabel(Text("Go forward 5 seconds"))
                }

                VStack(spacing: 8) {
                    Text("Fine Scrubbing")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ScrubberJoystick(value: $joystickValue) {
                        stopScrubbing()
                    }
                }

                Button("Save Alignment") {
                    model.seek(toSeconds: scrubbedTime)
                    if let draft = model.bookmarkDraftAtCurrentTime() {
                        model.appendBookmark(
                            from: draft, title: "Aligned PDF View", timestamp: scrubbedTime,
                            note: nil, voiceMemoFileName: nil)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .padding(.top)
            }
            .padding()
            .navigationTitle("Manual Alignment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                scrubbedTime = model.currentPlaybackTime
                model.pause()
            }
            .onDisappear {
                stopScrubbing()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .background { stopScrubbing() }
            }
            .onChange(of: joystickValue) { _, newValue in
                if newValue != 0 {
                    startScrubbing()
                } else {
                    stopScrubbing()
                }
            }
            .onChange(of: model.currentPlaybackTime) { _, newTime in
                if joystickValue == 0 && !model.isManualSeeking {
                    scrubbedTime = newTime
                }
            }
        }
    }

    private func startScrubbing() {
        model.startJoystickScrubbing { [self] _ in
            let speed = joystickValue * 10.0  // up to 10 seconds per 0.1s tick
            scrubbedTime = max(0, min(model.durationSeconds ?? .infinity, scrubbedTime + speed))
            model.seek(toSeconds: scrubbedTime)
        }
        model.startSnippetPlayback { [self] in scrubbedTime }
    }

    private func stopScrubbing() {
        model.stopJoystickScrubbing()
        model.stopSnippetPlayback()
    }
}
