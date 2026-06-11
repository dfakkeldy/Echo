import SwiftUI
import AppKit

/// Display mode for the transcript pane.
enum MacTranscriptDisplayMode: String, CaseIterable {
    case transcript = "Transcript"
    case wordCloud = "Word Cloud"
}

struct TranscriptPane: View {
    @Environment(TranscriptStore.self) var transcriptStore
    @Environment(MacPlayerModel.self) var player
    @Environment(TranscriptionManager.self) var transcriptionManager
    @Binding var searchText: String
    @State private var displayMode: MacTranscriptDisplayMode = .transcript
    @ScaledMetric(relativeTo: .body) private var wordCloudBaseSize: CGFloat = 10

    var currentHash: String {
        player.currentURL?.sha256Hash ?? ""
    }

    var segments: [TranscriptionSegment] {
        transcriptStore.transcriptions[currentHash] ?? []
    }

    var filteredSegments: [TranscriptionSegment] {
        if searchText.isEmpty { return segments }
        return segments.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }

    var wordCloud: [WordFrequency] {
        transcriptStore.wordClouds[currentHash] ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            if !segments.isEmpty && !transcriptionManager.isTranscribing {
                HStack {
                    Picker("Display", selection: $displayMode) {
                        ForEach(MacTranscriptDisplayMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Spacer()

                    exportButton
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }

            if transcriptionManager.isTranscribing || !transcriptionManager.liveLogStream.isEmpty {
                liveTerminalView
            } else if !segments.isEmpty {
                switch displayMode {
                case .transcript:
                    segmentsList
                case .wordCloud:
                    wordCloudView
                }
            } else {
                emptyState
            }
        }
    }

    // MARK: - Live terminal

    private var liveTerminalView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(transcriptionManager.liveLogStream) { entry in
                        Text(formattedLogLine(entry))
                            .font(.caption.monospaced())
                            .foregroundStyle(logColor(entry.kind))
                            .textSelection(.enabled)
                            .id(entry.id)
                    }
                }
                .padding(8)
                .padding(.top, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.black)
            .overlay(alignment: .topTrailing) {
                if !transcriptionManager.liveLogStream.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            transcriptionManager.liveLogStream.map(formattedLogLine).joined(separator: "\n"),
                            forType: .string
                        )
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .padding(4)
                    }
                    .buttonStyle(.borderless)
                    .padding(4)
                }
            }
            .onChange(of: transcriptionManager.liveLogStream.count) { _, _ in
                if let last = transcriptionManager.liveLogStream.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Segments list

    private var segmentsList: some View {
        List {
            ForEach(filteredSegments, id: \.startTime) { segment in
                Button {
                    player.seek(to: segment.startTime)
                } label: {
                    Text(segment.text)
                        .font(.body)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Word cloud

    private var wordCloudView: some View {
        Group {
            if wordCloud.isEmpty {
                ContentUnavailableView {
                    Label("No Word Cloud", systemImage: "text.word.spacing")
                } description: {
                    Text("Word frequencies will appear after a transcript is loaded.")
                }
            } else {
                ScrollView {
                    MacFlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                        ForEach(wordCloud.prefix(30)) { word in
                            Text(word.word)
                                .font(.system(size: fontSize(for: word.count)))
                                .fontWeight(fontWeight(for: word.count))
                                .foregroundStyle(color(for: word.count))
                                .lineLimit(1)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                        }
                    }
                    .padding()
                }
            }
        }
    }

    private var maxWordCount: Int { wordCloud.first?.count ?? 1 }

    private func fontSize(for count: Int) -> CGFloat {
        let fraction = CGFloat(count) / CGFloat(maxWordCount)
        return wordCloudBaseSize + fraction * 18
    }

    private func fontWeight(for count: Int) -> Font.Weight {
        let fraction = CGFloat(count) / CGFloat(maxWordCount)
        if fraction > 0.7 { return .bold }
        if fraction > 0.4 { return .semibold }
        if fraction > 0.2 { return .medium }
        return .regular
    }

    private func color(for count: Int) -> Color {
        let fraction = CGFloat(count) / CGFloat(maxWordCount)
        return .primary.opacity(0.4 + fraction * 0.6)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Transcript", systemImage: "text.quote")
        } description: {
            Text("Transcribe to see text here.")
        }
    }

    private var exportButton: some View {
        Button("Export Transcript") {
            if let url = player.currentURL {
                try? transcriptionManager.exportTranscript(for: url, segments: segments)
            }
        }
    }

    private func formattedLogLine(_ entry: TranscriptionLogEntry) -> String {
        switch entry.kind {
        case .status:
            return "[status] \(entry.message)"
        case .progress:
            return "[progress] \(entry.message)"
        case .segment:
            return "[segment] \(entry.message)"
        case .completed:
            return "[done] \(entry.message)"
        case .error:
            return "[error] \(entry.message)"
        case .debug:
            return "[debug] \(entry.message)"
        case .stderr:
            return "[stderr] \(entry.message)"
        }
    }

    private func logColor(_ kind: TranscriptionLogEntry.Kind) -> Color {
        switch kind {
        case .error, .stderr:
            return .red
        case .completed:
            return .mint
        case .segment:
            return .white
        case .progress:
            return .cyan
        case .debug:
            return .secondary
        case .status:
            return .green
        }
    }
}

// MARK: - macOS Flow Layout

private struct MacFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var maxHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += maxHeight + verticalSpacing
                maxHeight = 0
            }
            maxHeight = max(maxHeight, size.height)
            x += size.width + horizontalSpacing
        }

        return CGSize(width: width, height: y + maxHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + verticalSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            lineHeight = max(lineHeight, size.height)
            x += size.width + horizontalSpacing
        }
    }
}
