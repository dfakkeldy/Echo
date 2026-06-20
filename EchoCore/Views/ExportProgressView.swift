// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS)
    import GRDB
    import SwiftUI

    /// Exports a loaded book to a single chapterised `.m4b` and offers it via the
    /// system share sheet. `ExportSourceResolver` auto-detects whether the book is
    /// narrated (per-chapter cache) or imported (original on-disk tracks); both feed
    /// the shared `AudioExportService`, which concatenates the audio and stamps real
    /// Nero (`chpl`) + QuickTime (`chap`) chapter markers (see `ChapterMarkerWriter`).
    ///
    /// iOS-only: the macOS target has its own `MacAudioExportView` (NSSavePanel).
    struct ExportProgressView: View {
        /// The book whose audio to export (the `folderURL.absoluteString`
        /// key the narration pipeline writes under).
        let audiobookID: String
        /// Human-facing title, used for the exported file name and the share label.
        let bookTitle: String
        /// Where the per-chapter `.m4a` cache files live — resolved by the caller via
        /// `PlayerModel.narrationCacheDirectory()` rather than guessed here, so the
        /// view stays decoupled from the cache-location policy. Only consulted for
        /// narrated books; imported books read their original on-disk track files.
        let cacheDirectory: URL
        /// The DB the resolver reads to decide narrated-vs-imported and to fetch
        /// real per-chapter titles. Non-optional: the resolver needs it for imported
        /// books too, and the call site already has a writer in hand.
        let databaseWriter: DatabaseWriter

        @Environment(\.dismiss) private var dismiss

        @State private var isExporting = true
        @State private var exportedURL: URL?
        @State private var errorText: String?

        // When the resolved metadata is missing an author or cover, we pause and
        // ask the user to confirm/fill it in before exporting. We stash the already
        // resolved items + pre-filled metadata so `onConfirm` can run the export
        // without re-reading the source. `ExportMetadata` isn't `Identifiable`, so
        // the sheet is driven by `showingDetails` rather than `.sheet(item:)`.
        @State private var showingDetails = false
        @State private var pendingItems: [ExportItem] = []
        @State private var pendingMetadata = ExportMetadata(title: "", author: nil, coverArt: nil)

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
            .sheet(isPresented: $showingDetails) {
                ExportDetailsSheet(metadata: pendingMetadata) { confirmed in
                    isExporting = true
                    Task { await export(items: pendingItems, metadata: confirmed) }
                }
            }
        }

        private func runExport() async {
            // Auto-detect the source: a narrated book exports its per-chapter cache,
            // an imported book its original on-disk tracks — both funnel into the
            // shared `AudioExportService`. The resolver inspects the DB to choose.
            let source = ExportSourceResolver.resolve(
                audiobookID: audiobookID,
                databaseWriter: databaseWriter,
                cacheDirectory: cacheDirectory)
            do {
                let items = try await source.items()
                let meta = await ExportMetadataResolver.resolve(
                    audiobookID: audiobookID, fallbackTitle: bookTitle,
                    firstSourceURL: items.first?.url, databaseWriter: databaseWriter)
                // Complete metadata exports silently; otherwise hand off to the
                // confirm sheet, which re-enters `export(items:metadata:)` on confirm.
                if meta.isComplete {
                    await export(items: items, metadata: meta)
                } else {
                    pendingItems = items
                    pendingMetadata = meta
                    isExporting = false
                    showingDetails = true
                }
            } catch {
                errorText = error.localizedDescription
                isExporting = false
            }
        }

        /// Runs the actual concatenation + chapterised export and surfaces the
        /// result. Shared by the silent path and the confirm-sheet path so the
        /// export logic lives in exactly one place.
        private func export(items: [ExportItem], metadata: ExportMetadata) async {
            // The exported file is a one-shot share artifact, so the system temp dir
            // is the right home for it — it must NOT be confused with `cacheDirectory`,
            // which holds the durable per-chapter source audio we read from.
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent(ExportFileName.safe(bookTitle))
                .appendingPathExtension("m4b")
            do {
                try await AudioExportService().exportM4B(
                    items: items, outputURL: output, metadata: metadata)
                exportedURL = output
            } catch {
                errorText = error.localizedDescription
            }
            isExporting = false
        }
    }
#endif
