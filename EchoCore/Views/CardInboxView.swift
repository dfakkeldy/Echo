// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import os.log
import SwiftUI

/// Mark-later inbox: passages flagged for flashcard conversion, grouped by book.
struct CardInboxView: View {
    @Environment(PlayerModel.self) private var model
    @Environment(FreeTierGate.self) private var freeTierGate
    @Environment(\.dismiss) private var dismiss
    @State private var passages: [MarkedPassage] = []
    @State private var passageBeingConverted: MarkedPassage?
    @State private var loadError: String?
    private let logger = Logger(category: "CardInboxView")

    var body: some View {
        NavigationStack {
            Group {
                if let loadError {
                    ContentUnavailableView {
                        Label("Could Not Load Card Inbox", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("Try Again") {
                            Task { await load() }
                        }
                    }
                } else if passages.isEmpty {
                    ContentUnavailableView(
                        "Card Inbox Empty",
                        systemImage: "tray",
                        description: Text(
                            "Mark passages during playback to convert them into flashcards later.")
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
            .sheet(item: $passageBeingConverted) { passage in
                FlashcardCreationSheet(
                    sourceText: frontText(for: passage),
                    mediaTimestamp: passage.mediaTimestamp,
                    audiobookID: passage.audiobookID,
                    endTimestamp: passage.endTimestamp
                ) { cardID in
                    markConverted(passage, cardID: cardID)
                }
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func load() async {
        loadError = nil
        guard let db = model.databaseService else {
            passages = []
            loadError = String(localized: "The app database is unavailable. Reopen the book and try again.")
            return
        }
        do {
            let dao = MarkedPassageDAO(db: db.writer)
            let records = try dao.fetchAllInbox()

            // Build display models with book titles
            var result: [MarkedPassage] = []
            for r in records {
                let title = try await db.writer.read { db in
                    try String.fetchOne(
                        db, sql: "SELECT title FROM audiobook WHERE id = ?",
                        arguments: [r.audiobookID])
                }
                let created = (try? Date(r.createdAt, strategy: .iso8601)) ?? Date()
                result.append(
                    MarkedPassage(
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
        } catch {
            logger.error("Failed to load card inbox: \(error.localizedDescription)")
            passages = []
            loadError = String(localized: "The Card Inbox could not be loaded. Try again.")
        }
    }

    private func convertToFlashcard(_ passage: MarkedPassage) {
        if freeTierGate.canCreateFlashcards(adding: 1) {
            passageBeingConverted = passage
        } else {
            model.paywallContext = .flashcardCap
            model.showPaywall = true
        }
    }

    private func markConverted(_ passage: MarkedPassage, cardID: String) {
        guard let db = model.databaseService else {
            loadError = String(localized: "The app database is unavailable. Reopen the book and try again.")
            return
        }
        do {
            let dao = MarkedPassageDAO(db: db.writer)
            try dao.markConverted(id: passage.id, cardID: cardID)
            Task { await load() }
        } catch {
            logger.error("Failed to mark passage converted: \(error.localizedDescription)")
        }
    }

    private func dismissPassage(_ passage: MarkedPassage) {
        guard let db = model.databaseService else {
            loadError = String(localized: "The app database is unavailable. Reopen the book and try again.")
            return
        }
        do {
            let dao = MarkedPassageDAO(db: db.writer)
            try dao.dismiss(id: passage.id)
            Task { await load() }
        } catch {
            logger.error("Failed to save/dismiss passage: \(error.localizedDescription)")
        }
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        formatHMS(seconds)
    }

    private func frontText(for passage: MarkedPassage) -> String {
        passage.transcriptSnippet ?? "Marked at \(formatTimestamp(passage.mediaTimestamp))"
    }
}
