// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Browsable history of reconstructed listening sessions for one audiobook.
/// Tapping a row scopes the reader feed to that session.
struct SessionsListView: View {
    let audiobookID: String
    @Environment(DatabaseService.self) private var dbService

    @State private var sessions: [SessionSummary] = []
    @State private var isLoading = true
    @State private var loadError: String?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                ContentUnavailableView(
                    "Couldn't load sessions",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError))
            } else if sessions.isEmpty {
                ContentUnavailableView(
                    "No sessions yet",
                    systemImage: "clock",
                    description: Text(
                        "Play this book and your listening sessions will appear here."))
            } else {
                List(sessions) { session in
                    NavigationLink {
                        SessionDetailFeedView(audiobookID: audiobookID, session: session)
                    } label: {
                        sessionRow(session)
                    }
                }
            }
        }
        .navigationTitle("Sessions")
        .task { await load() }
    }

    @ViewBuilder
    private func sessionRow(_ session: SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.dateFormatter.string(from: session.startedAt))
                .font(.headline)
            if let range = session.chapterRangeLabel {
                Text(range)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Label("\(Int(session.minutesListened.rounded())) min", systemImage: "headphones")
                if session.hasRoute {
                    Label(
                        String(format: "%.1f mi", session.routeMiles),
                        systemImage: "map")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if session.bookmarkCount > 0 || session.cardCount > 0 || session.noteCount > 0 {
                HStack(spacing: 12) {
                    if session.bookmarkCount > 0 {
                        Label("\(session.bookmarkCount)", systemImage: "bookmark")
                    }
                    if session.cardCount > 0 {
                        Label("\(session.cardCount)", systemImage: "rectangle.on.rectangle")
                    }
                    if session.noteCount > 0 {
                        Label("\(session.noteCount)", systemImage: "note.text")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        isLoading = true
        loadError = nil
        let bookID = audiobookID
        let writer = dbService.writer
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try SessionSummaryService(db: writer).sessions(audiobookID: bookID)
            }.value
            sessions = result
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}
