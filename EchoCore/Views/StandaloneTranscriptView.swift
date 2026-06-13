import SwiftUI
import GRDB

/// A simplified reader shown when no EPUB or PDF companion exists but
/// a standalone transcript has been generated for the audiobook.
///
/// Displays a searchable list of transcribed segments ordered by time.
struct StandaloneTranscriptView: View {
    let audiobookID: String
    let db: DatabaseWriter

    @State private var segments: [StandaloneTranscriptRecord] = []
    @State private var searchText = ""

    var body: some View {
        Group {
            if segments.isEmpty {
                ContentUnavailableView(
                    "No Transcript",
                    systemImage: "waveform",
                    description: Text("The transcript has not been generated yet.")
                )
            } else {
                List(filteredSegments, id: \.id) { segment in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(segment.text)
                            .font(.body)
                        Text(
                            Duration.seconds(segment.startTime),
                            format: .time(pattern: .minuteSecond)
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .searchable(text: $searchText, prompt: "Search transcript...")
            }
        }
        .task { await loadSegments() }
    }

    private var filteredSegments: [StandaloneTranscriptRecord] {
        guard !searchText.isEmpty else { return segments }
        return segments.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }

    private func loadSegments() async {
        do {
            segments = try await db.read { db in
                try StandaloneTranscriptRecord
                    .filter(Column("audiobook_id") == audiobookID)
                    .order(Column("start_time").asc)
                    .fetchAll(db)
            }
        } catch {
            segments = []
        }
    }
}
