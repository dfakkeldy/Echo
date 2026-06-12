import SwiftUI

struct ManualAlignmentSheet: View {
    let folderURL: URL
    @Environment(PlayerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    
    @State private var scrubbedTime: TimeInterval = 0
    @State private var joystickValue: Double = 0
    @State private var joystickTimer: Timer?
    @State private var snippetTimer: Timer?
    
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
                    
                    Button {
                        model.togglePlayPause()
                    } label: {
                        Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 64))
                    }
                    
                    Button {
                        scrubbedTime = min(model.durationSeconds ?? .infinity, scrubbedTime + 5)
                        model.seek(toSeconds: scrubbedTime)
                    } label: {
                        Image(systemName: "goforward.5")
                            .font(.title)
                    }
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
                        model.appendBookmark(from: draft, title: "Aligned PDF View", timestamp: scrubbedTime, note: nil, voiceMemoFileName: nil)
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
                if newValue != 0 && joystickTimer == nil {
                    startScrubbing()
                } else if newValue == 0 {
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
        joystickTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let speed = joystickValue * 10.0 // up to 10 seconds per 0.1s tick
                scrubbedTime = max(0, min(model.durationSeconds ?? .infinity, scrubbedTime + speed))
                model.seek(toSeconds: scrubbedTime)
            }
        }

        snippetTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            MainActor.assumeIsolated {
                playScrubSnippet()
            }
        }
    }
    
    private func stopScrubbing() {
        joystickTimer?.invalidate()
        joystickTimer = nil
        snippetTimer?.invalidate()
        snippetTimer = nil
    }
    
    private func playScrubSnippet() {
        guard !model.isPlaying else { return }
        let tracks = model.state.tracks
        let currentIndex = model.currentIndex
        guard tracks.indices.contains(currentIndex) else { return }
        
        let url = tracks[currentIndex].url
        let duration = model.durationSeconds ?? .infinity
        let start = min(scrubbedTime, max(0, duration - 0.2))
        
        model.snippetPlayer.play(url: url, startTime: start, endTime: start + 0.2)
    }
}