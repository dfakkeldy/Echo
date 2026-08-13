// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import SwiftUI
import os.log

/// macOS "Card Inbox" — passages flagged during playback, reviewed and either
/// converted into flashcards or dismissed. Mac-native over the shared,
/// macOS-clean `MarkedPassageDAO` + `FlashcardDAO`. (The iOS `CardInboxView` /
/// `FlashcardCreationSheet` depend on `PlayerModel` + the Pro `FreeTierGate` and
/// aren't part of the macOS target; macOS has no Pro cap, so conversion is
/// ungated.) Reached via Study ▸ Card Inbox….
struct MacCardInboxView: View {
    let db: DatabaseWriter

    @Environment(\.dismiss) private var dismiss
    @State private var passages: [MarkedPassage] = []
    @State private var passageBeingConverted: MarkedPassage?
    @State private var loadError: String?
    private let logger = Logger(subsystem: "com.echo.audiobooks", category: "MacCardInbox")

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Card Inbox").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Divider()
            content
        }
        .frame(width: 520, height: 420)
        .padding()
        .task { await load() }
        .sheet(item: $passageBeingConverted) { passage in
            MacFlashcardCreateSheet(
                db: db,
                audiobookID: passage.audiobookID,
                mediaTimestamp: passage.mediaTimestamp,
                endTimestamp: passage.endTimestamp,
                initialFront: passage.transcriptSnippet ?? ""
            ) { cardID in
                markConverted(passage, cardID: cardID)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let loadError {
            ContentUnavailableView(
                "Could not load Card Inbox",
                systemImage: "exclamationmark.triangle",
                description: Text(loadError))
        } else if passages.isEmpty {
            ContentUnavailableView(
                "Card Inbox empty",
                systemImage: "tray",
                description: Text(
                    "Mark passages during playback to convert them into flashcards later."))
        } else {
            List(passages) { passage in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(passage.bookTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(formatHMS(passage.mediaTimestamp))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    if let snippet = passage.transcriptSnippet {
                        Text(snippet)
                            .font(.callout)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                    HStack(spacing: 12) {
                        Button {
                            passageBeingConverted = passage
                        } label: {
                            Label("Card", systemImage: "rectangle.stack.badge.plus")
                        }
                        .controlSize(.small)

                        Button(role: .destructive) {
                            dismissPassage(passage)
                        } label: {
                            Label("Dismiss", systemImage: "trash")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func load() async {
        loadError = nil
        do {
            let records = try MarkedPassageDAO(db: db).fetchAllInbox()
            var result: [MarkedPassage] = []
            for r in records {
                let title = try await db.read { db in
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
                        createdAt: created))
            }
            passages = result
        } catch {
            logger.error(
                "Failed to load card inbox: \(error.localizedDescription, privacy: .public)")
            passages = []
            loadError = "The Card Inbox could not be loaded. Try again."
        }
    }

    private func markConverted(_ passage: MarkedPassage, cardID: String) {
        do {
            try MarkedPassageDAO(db: db).markConverted(id: passage.id, cardID: cardID)
            Task { await load() }
        } catch {
            logger.error(
                "Failed to mark passage converted: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func dismissPassage(_ passage: MarkedPassage) {
        do {
            try MarkedPassageDAO(db: db).dismiss(id: passage.id)
            Task { await load() }
        } catch {
            logger.error(
                "Failed to dismiss passage: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Minimal Mac flashcard-creation sheet used by the Card Inbox convert action.
/// Builds a `Flashcard` directly (no Pro gate) — the iOS FlashcardCreationSheet
/// isn't macOS-compatible.
private struct MacFlashcardCreateSheet: View {
    let db: DatabaseWriter
    let audiobookID: String
    let mediaTimestamp: TimeInterval
    let endTimestamp: TimeInterval?
    let initialFront: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var front: String = ""
    @State private var back: String = ""
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Flashcard").font(.headline)
            Text("Front").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $front)
                .frame(height: 80)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            Text("Back").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $back)
                .frame(height: 80)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(width: 440)
        .padding()
        .onAppear { if front.isEmpty { front = initialFront } }
    }

    private func save() {
        let cardID = UUID().uuidString
        let now = Date().ISO8601Format()
        let card = Flashcard(
            id: cardID,
            audiobookID: audiobookID,
            frontText: front,
            backText: back,
            mediaTimestamp: mediaTimestamp,
            endTimestamp: endTimestamp,
            triggerTiming: .manualOnly,
            nextReviewDate: now,
            intervalDays: 0,
            easeFactor: 2.5,
            repetitions: 0,
            lastReviewedAt: nil,
            lastGrade: nil,
            isEnabled: true,
            deckID: nil,
            tags: "",
            mediaJSON: nil,
            sourceBlockID: nil,
            playlistPosition: nil,
            createdAt: now,
            modifiedAt: now)
        do {
            try FlashcardDAO(db: db).insert(card)
            onSave(cardID)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
