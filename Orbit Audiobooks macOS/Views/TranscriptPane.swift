import SwiftUI
import AppKit
import CryptoKit

struct TranscriptPane: View {
    @EnvironmentObject var transcriptStore: TranscriptStore
    @EnvironmentObject var player: MacPlayerModel
    @ObservedObject var transcriptionManager: TranscriptionManager
    @Binding var searchText: String

    var currentHash: String {
        guard let path = player.currentURL?.path else { return "" }
        let data = Data(path.utf8)
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    var segments: [TranscriptionSegment] {
        transcriptStore.transcriptions[currentHash] ?? []
    }

    var filteredSegments: [TranscriptionSegment] {
        if searchText.isEmpty { return segments }
        return segments.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack {
            if !segments.isEmpty && !transcriptionManager.isTranscribing {
                exportButton
            }

            if transcriptionManager.isTranscribing || !transcriptionManager.liveLogStream.isEmpty {
                liveTerminalView
            } else if !segments.isEmpty {
                segmentsList
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
                    ForEach(Array(transcriptionManager.liveLogStream.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(line.hasPrefix("[error]") ? Color.red : Color.green)
                            .textSelection(.enabled)
                    }
                }
                .padding(8)
                .padding(.top, 24) // room for the copy button
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.black)
            .overlay(alignment: .topTrailing) {
                if !transcriptionManager.liveLogStream.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            transcriptionManager.liveLogStream.joined(separator: "\n"),
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
                if let last = transcriptionManager.liveLogStream.indices.last {
                    withAnimation {
                        proxy.scrollTo(last, anchor: .bottom)
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
        .padding()
    }
}

extension Optional {
    var isNil: Bool { self == nil }
}
