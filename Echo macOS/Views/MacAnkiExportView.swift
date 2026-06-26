// SPDX-License-Identifier: GPL-3.0-or-later
//
//  MacAnkiExportView.swift
//  Echo macOS
//
//  WS-12: Export flashcards to Anki — either as an .apkg file or directly
//  to AnkiConnect (if the Anki addon is running on localhost:8765).
//

import GRDB
import SwiftUI
import UniformTypeIdentifiers

struct MacAnkiExportView: View {
    @Environment(DatabaseService.self) private var dbService

    @State private var selectedDeckIDs = Set<String>()
    @State private var decks: [Deck] = []
    @State private var isExporting = false
    @State private var exportPath = ""
    @State private var exportError: String?
    @State private var ankiConnectAvailable = false
    @State private var ankiStatusMessage = ""
    @Environment(\.dismiss) var dismiss

    // MARK: - Body

    var body: some View {
        VStack(spacing: 16) {
            Text("Export for Anki")
                .font(.title)

            if !ankiStatusMessage.isEmpty {
                HStack(spacing: 6) {
                    Image(
                        systemName: ankiConnectAvailable
                            ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                    )
                    .foregroundStyle(ankiConnectAvailable ? .green : .orange)
                    Text(ankiStatusMessage)
                        .font(.caption)
                }
            }

            List(decks, id: \.id, selection: $selectedDeckIDs) { deck in
                HStack {
                    Text(deck.name)
                        .font(.body)
                    Spacer()
                    Text(deck.source)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if selectedDeckIDs.contains(deck.id) {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.accent)
                    }
                }
                .padding(.vertical, 2)
            }
            .listStyle(.bordered)

            if let error = exportError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            if !exportPath.isEmpty {
                Text("Saved to: \(exportPath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 12) {
                Button("Export to File...") {
                    exportToFile()
                }
                .disabled(selectedDeckIDs.isEmpty || isExporting)

                Button("Send to Anki") {
                    sendToAnkiConnect()
                }
                .disabled(selectedDeckIDs.isEmpty || isExporting || !ankiConnectAvailable)
            }
        }
        .padding()
        .frame(width: 440, height: 400)
        .task {
            await loadDecks()
            await checkAnkiConnect()
        }
    }

    // MARK: - Load Data

    private func loadDecks() async {
        do {
            let loaded: [Deck] = try await dbService.readAsync { db in
                try Deck.fetchAll(db)
            }
            decks = loaded
        } catch {
            exportError = "Failed to load decks: \(error.localizedDescription)"
        }
    }

    private func checkAnkiConnect() async {
        do {
            let reachable = try await AnkiConnectBridge.healthCheck()
            await MainActor.run {
                ankiConnectAvailable = reachable
                ankiStatusMessage =
                    reachable
                    ? "AnkiConnect detected on localhost:8765"
                    : "AnkiConnect not available — export to file instead"
            }
        } catch {
            await MainActor.run {
                ankiConnectAvailable = false
                ankiStatusMessage = "AnkiConnect not available — export to file instead"
            }
        }
    }

    // MARK: - Actions

    private func exportToFile() {
        exportError = nil

        let panel = NSSavePanel()
        panel.title = String(localized: "Export Flashcards as .apkg")
        panel.allowedContentTypes = [UTType(filenameExtension: "apkg") ?? .zip]
        panel.nameFieldStringValue = "Echo_Flashcards.apkg"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            isExporting = true
            let selectedDeckIDsSnapshot = selectedDeckIDs
            let writer = dbService.writer
            Task {
                do {
                    let service = MacApkgExportService()
                    let apkgURL = try await service.export(
                        deckIDs: Array(selectedDeckIDsSnapshot), db: writer)

                    // Copy to user-chosen location
                    try? FileManager.default.removeItem(at: url)
                    try FileManager.default.copyItem(at: apkgURL, to: url)
                    // Clean up temp file
                    try? FileManager.default.removeItem(at: apkgURL)

                    await MainActor.run {
                        exportPath = url.path
                        isExporting = false
                    }
                } catch {
                    await MainActor.run {
                        exportError = error.localizedDescription
                        isExporting = false
                    }
                }
            }
        }
    }

    private func sendToAnkiConnect() {
        exportError = nil
        isExporting = true

        let selectedDeckIDsSnapshot = selectedDeckIDs
        let decksSnapshot = decks
        Task {
            do {
                // Load flashcards for selected decks
                let cards: [Flashcard] = try await dbService.readAsync { db in
                    var allCards: [Flashcard] = []
                    for deckID in selectedDeckIDsSnapshot {
                        let deckCards =
                            try Flashcard
                            .filter(Column("deck_id") == deckID)
                            .fetchAll(db)
                        allCards.append(contentsOf: deckCards)
                    }
                    return allCards
                }

                guard !cards.isEmpty else {
                    await MainActor.run {
                        exportError = "No flashcards found in selected decks"
                        isExporting = false
                    }
                    return
                }

                // Get deck names
                var deckNames: [String: String] = [:]
                for deckID in selectedDeckIDsSnapshot {
                    if let deck = decksSnapshot.first(where: { $0.id == deckID }) {
                        deckNames[deckID] = deck.name
                    }
                }

                let bridge = AnkiConnectBridge()
                try await bridge.addCards(cards: cards, deckNames: deckNames)

                await MainActor.run {
                    exportPath = "Sent to Anki successfully (\(cards.count) cards)"
                    isExporting = false
                    ankiStatusMessage = "Sent \(cards.count) cards to Anki"
                }
            } catch {
                await MainActor.run {
                    exportError = "AnkiConnect error: \(error.localizedDescription)"
                    isExporting = false
                }
            }
        }
    }
}

// MARK: - AnkiConnect Bridge

/// Minimal AnkiConnect client.
/// AnkiConnect is an Anki addon that exposes a JSON-RPC API on localhost:8765.
/// https://foosoft.net/projects/anki-connect/
private struct AnkiConnectBridge {
    private let baseURL = URL(string: "http://localhost:8765")!
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    // MARK: - Health Check

    /// Checks whether AnkiConnect is reachable by requesting the version.
    static func healthCheck() async throws -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: config)

        let body: [String: Any] = ["action": "version", "version": 6]
        let request = try makeURLRequest(with: body)

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                httpResponse.statusCode == 200
            else {
                return false
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let result = json?["result"] as? Int, result >= 6 {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    // MARK: - Add Cards

    /// Sends flashcards to Anki via AnkiConnect's `addNotes` action.
    func addCards(cards: [Flashcard], deckNames: [String: String]) async throws {
        var notes: [[String: Any]] = []

        for card in cards {
            // Determine deck name: use the mapped name or fallback to "Default"
            let deckName: String
            if let deckID = card.deckID, let name = deckNames[deckID] {
                deckName = name
            } else {
                deckName = "Echo Imported"
            }

            let note: [String: Any] = [
                "deckName": deckName,
                "modelName": "Basic",
                "fields": [
                    "Front": card.frontText,
                    "Back": card.backText,
                ],
                "tags": ["echo", "echo-imported"],
                "options": [
                    "allowDuplicate": false
                ],
            ]
            notes.append(note)
        }

        // AnkiConnect's addNotes can handle up to a reasonable batch size
        let chunkSize = 50
        for chunk in notes.chunked(into: chunkSize) {
            let body: [String: Any] = [
                "action": "addNotes",
                "version": 6,
                "params": ["notes": chunk],
            ]
            let request = try Self.makeURLRequest(with: body)
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                httpResponse.statusCode == 200
            else {
                throw AnkiConnectError.requestFailed
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let error = json?["error"] as? String, !error.isEmpty {
                throw AnkiConnectError.apiError(error)
            }
        }
    }

    // MARK: - Helpers

    private static func makeURLRequest(with body: [String: Any]) throws -> URLRequest {
        let url = URL(string: "http://localhost:8765")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    enum AnkiConnectError: LocalizedError {
        case requestFailed
        case apiError(String)
        case notRunning

        var errorDescription: String? {
            switch self {
            case .requestFailed:
                return
                    "Failed to connect to AnkiConnect. Make sure Anki is running with the AnkiConnect addon installed."
            case .apiError(let msg): return "AnkiConnect error: \(msg)"
            case .notRunning: return "AnkiConnect is not reachable on localhost:8765"
            }
        }
    }
}

// MARK: - Array Chunking

extension Array {
    fileprivate func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
