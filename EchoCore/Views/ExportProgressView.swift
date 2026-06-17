// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS)
    import GRDB
    import SwiftUI

    /// Exports a book's rendered narration to a single chapterised `.m4b` and offers
    /// it via the system share sheet. Driven entirely by `NarrationExportService`,
    /// which concatenates the cached per-chapter `.m4a` files and stamps real Nero
    /// (`chpl`) + QuickTime (`chap`) chapter markers (see `ChapterMarkerWriter`).
    ///
    /// iOS-only, mirroring the rest of the narration feature: the macOS target
    /// excludes this file (it has no narration cache to export from).
    struct ExportProgressView: View {
        /// The book whose narration cache to export (the `folderURL.absoluteString`
        /// key the narration pipeline writes under).
        let audiobookID: String
        /// Human-facing title, used for the exported file name and the share label.
        let bookTitle: String
        /// Where the per-chapter `.m4a` cache files live — resolved by the caller via
        /// `PlayerModel.narrationCacheDirectory()` rather than guessed here, so the
        /// view stays decoupled from the cache-location policy.
        let cacheDirectory: URL
        /// Supplies real per-chapter titles from the book's narration `TrackRecord`s.
        /// Without it the export falls back to "Chapter N" labels.
        let databaseWriter: DatabaseWriter?

        @Environment(\.dismiss) private var dismiss

        @State private var isExporting = true
        @State private var exportedURL: URL?
        @State private var errorText: String?

        var body: some View {
            VStack(spacing: 20) {
                if isExporting {
                    ProgressView("Exporting M4B with chapters…")
                } else if let exportedURL {
                    Label("Export complete", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    ShareLink(item: exportedURL) {
                        Label("Share \(bookTitle).m4b", systemImage: "square.and.arrow.up")
                    }
                } else if let errorText {
                    Label(errorText, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                    Button("Done") { dismiss() }
                }
            }
            .padding()
            .task { await runExport() }
        }

        private func runExport() async {
            let service = NarrationExportService()
            // The exported file is a one-shot share artifact, so the system temp dir
            // is the right home for it — it must NOT be confused with `cacheDirectory`,
            // which holds the durable per-chapter source audio we read from.
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent(Self.safeFileName(bookTitle))
                .appendingPathExtension("m4b")
            do {
                try await service.exportM4B(
                    for: audiobookID,
                    bookTitle: bookTitle,
                    cacheDirectory: cacheDirectory,
                    outputURL: output,
                    databaseWriter: databaseWriter)
                exportedURL = output
            } catch {
                errorText = error.localizedDescription
            }
            isExporting = false
        }

        /// Strips path separators and other characters that would break a file name,
        /// so a book titled "Vol. 1/2" can't escape the temp directory.
        static func safeFileName(_ title: String) -> String {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
            let cleaned = trimmed.components(separatedBy: illegal).joined(separator: "-")
            return cleaned.isEmpty ? "Narration" : cleaned
        }
    }
#endif
