// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS)
    import GRDB
    import SwiftUI

    struct AllStudyNotesExportView: View {
        let databaseWriter: DatabaseWriter

        @Environment(\.dismiss) private var dismiss

        @State private var isExporting = true
        @State private var exportedURL: URL?
        @State private var errorText: String?

        var body: some View {
            NavigationStack {
                VStack(spacing: 20) {
                    if isExporting {
                        ProgressView("Exporting all study notes...")
                    } else if let exportedURL {
                        Label("All study notes ready", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        ShareLink(item: exportedURL) {
                            Label("Share All Study Notes (.zip)", systemImage: "square.and.arrow.up")
                        }
                    } else if let errorText {
                        Label(errorText, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()
                .navigationTitle("Export All Study Notes")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .task { runExport() }
            }
        }

        private func runExport() {
            do {
                let dataSource = StudyNotesExportDatabaseSource(databaseWriter: databaseWriter)
                exportedURL = try StudyNotesExportService().exportAllArchive(
                    books: dataSource.books(),
                    bookmarkProvider: { (try? dataSource.bookmarks(for: $0)) ?? [] },
                    noteProvider: { (try? dataSource.notes(for: $0)) ?? [] },
                    flashcardProvider: { (try? dataSource.cards(for: $0)) ?? [] },
                    chapterProvider: { (try? dataSource.chapters(for: $0)) ?? [] }
                )
            } catch {
                errorText = error.localizedDescription
            }
            isExporting = false
        }
    }
#endif
