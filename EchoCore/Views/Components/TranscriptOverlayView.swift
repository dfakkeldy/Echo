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
    @State private var searchText: String = ""

    /// Pro unlock is required in production; debug builds bypass for testing.
    private var hasTranscriptAccess: Bool {
#if DEBUG
        true
#else
        storeManager.hasUnlockedPro
#endif
    }

    private var filteredSegments: [TranscriptionSegment] {
        if searchText.isEmpty { return player.transcription }
        return player.transcription.filter {
            $0.text.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            content

            if hasTranscriptAccess, !player.transcription.isEmpty {
                VStack(spacing: 0) {
                    // Always-visible header with mode picker and expand/collapse button.
                    HStack {
                        Picker("Display", selection: $displayMode) {
                            ForEach(TranscriptDisplayMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        Spacer()

                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isExpanded.toggle()
                            }
                        } label: {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)

                    // Search field in transcript mode.
                    if displayMode == .transcript {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            TextField("Search transcript...", text: $searchText)
                                .textFieldStyle(.plain)
                            if !searchText.isEmpty {
                                Button {
                                    searchText = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)

                        if !searchText.isEmpty {
                            Text(String(localized: "\(filteredSegments.count) of \(player.transcription.count) segments"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                        }
                    }

                    displayContent
                        .frame(maxHeight: isExpanded ? .infinity : 130)
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
        .onAppear {
            player.isTranscriptProcessingEnabled = true
        }
        .onDisappear {
            player.isTranscriptProcessingEnabled = false
        }
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
        if !searchText.isEmpty && filteredSegments.isEmpty {
            ContentUnavailableView(
                "No Results",
                systemImage: "magnifyingglass",
                description: Text(String(localized: "No transcript segments match \"\(searchText)\"."))
            )
            .padding()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(filteredSegments) { segment in
                            TranscriptRowView(
                                segment: segment,
                                isActive: isActive(segment),
                                searchText: searchText
                            )
                            .id(segment.id)
                        }
                    }
                    .padding()
                    .onChange(of: player.progressFraction) {
                        // Don't auto-scroll while the user is searching.
                        guard searchText.isEmpty, let active = activeSegment else { return }
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
