import SwiftUI
import GRDB

/// Mark-later inbox: passages flagged for flashcard conversion, grouped by book.
struct CardInboxView: View {
    @Environment(PlayerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var passages: [MarkedPassage] = []
    @State private var inboxCount: Int = 0

    var body: some View {
        NavigationStack {
            Group {
                if passages.isEmpty {
                    ContentUnavailableView(
                        "Card Inbox Empty",
                        systemImage: "tray",
                        description: Text("Mark passages during playback to convert them into flashcards later.")
                    )
                } else {
                    List {
                        ForEach(passages) { passage in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(passage.bookTitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(formatTimestamp(passage.mediaTimestamp))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if let snippet = passage.transcriptSnippet {
                                    Text(snippet)
                                        .font(.callout)
                                        .lineLimit(3)
                                }
                                HStack(spacing: 12) {
                                    Button {
                                        convertToFlashcard(passage)
                                    } label: {
                                        Label("Card", systemImage: "rectangle.stack.badge.plus")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)

                                    Button(role: .destructive) {
                                        dismissPassage(passage)
                                    } label: {
                                        Label("Dismiss", systemImage: "trash")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.borderless)
                                    .controlSize(.small)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Card Inbox")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func load() async {
        guard let db = model.databaseService else { return }
        do {
            let dao = MarkedPassageDAO(db: db.writer)
            inboxCount = (try? dao.inboxCount()) ?? 0
            let records = (try? dao.fetchAllInbox()) ?? []

            // Build display models with book titles
            var result: [MarkedPassage] = []
            for r in records {
                let title = try? await db.writer.read { db in
                    try String.fetchOne(db, sql: "SELECT title FROM audiobook WHERE id = ?", arguments: [r.audiobookID])
                }
                let formatter = ISO8601DateFormatter()
                let created = formatter.date(from: r.createdAt) ?? Date()
                result.append(MarkedPassage(
                    id: r.id,
                    audiobookID: r.audiobookID,
                    bookTitle: title ?? "Unknown Book",
                    mediaTimestamp: r.mediaTimestamp,
                    endTimestamp: r.endTimestamp,
                    transcriptSnippet: r.transcriptSnippet,
                    status: .inbox,
                    convertedCardID: r.convertedCardID,
                    note: r.note,
                    createdAt: created
                ))
            }
            passages = result
        }
    }

    private func convertToFlashcard(_ passage: MarkedPassage) {
        guard let db = model.databaseService else { return }
        let cardID = UUID().uuidString
        let frontText = passage.transcriptSnippet ?? "Marked at \(formatTimestamp(passage.mediaTimestamp))"
        var card = Flashcard(
            id: cardID,
            audiobookID: passage.audiobookID,
            frontText: frontText,
            backText: "",
            mediaTimestamp: passage.mediaTimestamp,
            endTimestamp: passage.endTimestamp,
            triggerTiming: .manualOnly,
            nextReviewDate: nil,
            intervalDays: 0,
            easeFactor: 2.5,
            repetitions: 0,
            lastReviewedAt: nil,
            lastGrade: nil,
            isEnabled: true,
            deckID: nil,
            tags: nil,
            mediaJSON: nil,
            sourceBlockID: nil,
            playlistPosition: nil,
            createdAt: Date().ISO8601Format(),
            modifiedAt: Date().ISO8601Format()
        )
        do {
            try db.writer.write { db in try card.insert(db) }
            let dao = MarkedPassageDAO(db: db.writer)
            try dao.markConverted(id: passage.id, cardID: cardID)
            Task { await load() }
        } catch { }
    }

    private func dismissPassage(_ passage: MarkedPassage) {
        guard let db = model.databaseService else { return }
        do {
            let dao = MarkedPassageDAO(db: db.writer)
            try dao.dismiss(id: passage.id)
            Task { await load() }
        } catch { }
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
