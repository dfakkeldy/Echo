import SwiftUI
import CryptoKit

struct TranscriptPane: View {
    @EnvironmentObject var transcriptStore: TranscriptStore
    @EnvironmentObject var player: MacPlayerModel
    @StateObject private var transcriptionManager = TranscriptionManager()
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
// ...

    var body: some View {
        VStack {
            if !segments.isEmpty {
                Button("Export Transcript") {
                    if let url = player.currentURL {
                        try? transcriptionManager.exportTranscript(for: url, segments: segments)
                    }
                }
                .padding()
            }
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
            .overlay {
                if segments.isEmpty && !player.currentURL.isNil {
                    Text("Transcribe to see text here.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

extension Optional {
    var isNil: Bool { self == nil }
}
