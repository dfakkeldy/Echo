import SwiftUI
import WatchKit
import AVFoundation

// MARK: - Watch Bookmarks List
//
// Renders the in-session bookmarks the user has created from the watch.
// The view reacts to `WatchViewModel.bookmarks` (an `@Observable` array),
// so it updates seamlessly the moment a Quick Bookmark is appended — no
// extra plumbing required. Rows render audio playback controls *only*
// when the bookmark carries a non-nil `audioURL`, satisfying the design
// goal that generic bookmarks remain lightweight.

struct WatchBookmarksView: View {
    let viewModel: WatchViewModel

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.bookmarks.isEmpty {
                    ContentUnavailableView(
                        "No Bookmarks",
                        systemImage: "bookmark",
                        description: Text("Tap Quick Bookmark to drop a generic marker, or Record Note to attach a voice memo.")
                    )
                } else {
                    List(viewModel.bookmarks) { bookmark in
                        WatchBookmarkRow(bookmark: bookmark)
                    }
                }
            }
            .navigationTitle("Bookmarks")
        }
    }
}

// MARK: - Row

private struct WatchBookmarkRow: View {
    let bookmark: WatchBookmark
    @State private var isPlaying = false
    @State private var audioPlayer: AVAudioPlayer?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: bookmark.hasAudio ? "waveform" : "bookmark.fill")
                .foregroundStyle(bookmark.hasAudio ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.secondary))


            VStack(alignment: .leading, spacing: 2) {
                Text(bookmark.title)
                    .font(.system(.body, design: .rounded))
                    .lineLimit(1)
                Text(formatHMS(bookmark.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer()

            // Only render playback controls for bookmarks that actually
            // carry an audio payload. Generic bookmarks render no button.
            if bookmark.hasAudio {
                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "Stop voice memo" : "Play voice memo")
            }
        }
    }

    private func togglePlayback() {
        if isPlaying {
            audioPlayer?.stop()
            audioPlayer = nil
            isPlaying = false
            return
        }

        guard let url = bookmark.audioURL,
              FileManager.default.fileExists(atPath: url.path)
        else { return }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            player.play()
            audioPlayer = player
            isPlaying = true
        } catch {
#if DEBUG
            print("Watch bookmark audio playback failed: \(error)")
#endif
        }
    }

}
