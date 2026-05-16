import SwiftUI

/// Display mode for the transcript overlay.
enum TranscriptDisplayMode: String, CaseIterable {
    case transcript = "Transcript"
    case wordCloud = "Word Cloud"
}

struct TranscriptOverlayView<Content: View>: View {
    @Environment(PlayerModel.self) private var player
    @Environment(StoreManager.self) private var storeManager
    @Binding var isExpanded: Bool
    @ViewBuilder let content: Content

    @State private var displayMode: TranscriptDisplayMode = .transcript

    var body: some View {
        ZStack(alignment: .bottom) {
            content

            if storeManager.hasUnlockedPro, !player.transcription.isEmpty {
                VStack(spacing: 0) {
                    if isExpanded {
                        Picker("Display", selection: $displayMode) {
                            ForEach(TranscriptDisplayMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                    }

                    displayContent
                        .frame(maxHeight: isExpanded ? .infinity : 160)
                }
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.quaternary, lineWidth: 1)
                )
                .padding(12)
            }
        }
        .padding(.horizontal, 16)
        .animation(.easeInOut(duration: 0.25), value: player.currentDisplayArtworkVersion)
    }

    @ViewBuilder
    private var displayContent: some View {
        switch displayMode {
        case .transcript:
            transcriptList
        case .wordCloud:
            wordCloudContent
        }
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(player.transcription) { segment in
                        Text(segment.text)
                            .font(.body)
                            .padding(8)
                            .background(isActive(segment) ? Color.accentColor.opacity(0.3) : Color.clear)
                            .cornerRadius(8)
                            .onTapGesture {
                                player.seek(toSeconds: segment.startTime)
                            }
                            .id(segment.id)
                    }
                }
                .padding()
                .onChange(of: player.progressFraction) {
                    if let active = activeSegment {
                        withAnimation {
                            proxy.scrollTo(active.id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Word Cloud

    @ViewBuilder
    private var wordCloudContent: some View {
        if player.currentChapterWordCloud.isEmpty {
            ContentUnavailableView(
                "No Word Cloud",
                systemImage: "text.word.spacing",
                description: Text("Word frequencies will appear after transcription data and chapter markers are loaded.")
            )
        } else {
            ScrollView {
                WordCloudView(words: player.currentChapterWordCloud)
                    .padding()
            }
        }
    }

    // MARK: - Helpers

    private var activeSegment: TranscriptionSegment? {
        let currentTime = player.currentPlaybackTime
        return player.transcription.first { currentTime >= $0.startTime && currentTime <= $0.endTime }
    }

    private func isActive(_ segment: TranscriptionSegment) -> Bool {
        activeSegment?.id == segment.id
    }
}
