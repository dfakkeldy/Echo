// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS)
    import GRDB
    import SwiftUI

    struct StudyNotesExportView: View {
        let audiobookID: String
        let bookTitle: String
        let sourceFolderURL: URL?
        let databaseWriter: DatabaseWriter
        let chapters: [Chapter]

        @Environment(\.dismiss) private var dismiss

        @State private var isExporting = true
        @State private var exportedURL: URL?
        @State private var errorText: String?

        var body: some View {
            VStack(spacing: 20) {
                if isExporting {
                    ProgressView("Exporting study notes...")
                } else if let exportedURL {
                    Label("Study notes ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    ShareLink(item: exportedURL) {
                        Label("Share Study Notes (.zip)", systemImage: "square.and.arrow.up")
                    }
                } else if let errorText {
                    Label(errorText, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                    Button("Done") { dismiss() }
                }
            }
            .padding()
            .task { runExport() }
        }

        private func runExport() {
            do {
                let dataSource = StudyNotesExportDatabaseSource(databaseWriter: databaseWriter)
                exportedURL = try StudyNotesExportService().exportArchive(
                    bookID: audiobookID,
                    bookTitle: bookTitle,
                    sourceFolderURL: sourceFolderURL,
                    bookmarks: dataSource.bookmarks(for: audiobookID),
                    notes: dataSource.notes(for: audiobookID),
                    flashcards: dataSource.cards(for: audiobookID),
                    chapters: dataSource.chapters(
                        for: audiobookID,
                        fallingBackToDatabaseWhen: chapters
                    )
                )
            } catch {
                errorText = error.localizedDescription
            }
            isExporting = false
        }
    }
#endif
