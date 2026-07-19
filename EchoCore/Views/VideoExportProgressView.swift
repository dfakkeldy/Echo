// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS)
    import GRDB
    import SwiftUI

    /// Exports the loaded book's Visual Listening slideshow as an MP4, SRT, and
    /// chapter-list bundle. The view owns the structured export task, so dismissing
    /// the sheet cooperatively cancels `VideoExportService` without a detached task.
    struct VideoExportProgressView: View {
        let audiobookID: String
        let bookTitle: String
        let cacheDirectory: URL
        let databaseWriter: DatabaseWriter

        @Environment(\.dismiss) private var dismiss

        @State private var isExporting = true
        @State private var fraction = 0.0
        @State private var output: VideoExportService.Output?
        @State private var errorText: String?

        var body: some View {
            NavigationStack {
                VStack(spacing: 20) {
                    if isExporting {
                        ProgressView(value: fraction) {
                            Text("Exporting slideshow video…")
                        }
                        .accessibilityValue(
                            Text(fraction, format: .percent.precision(.fractionLength(0))))

                        Text("Rendering the slideshow — this can take a while for long books.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if let output {
                        Label("Export complete", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        ShareLink(
                            items: [output.videoURL, output.srtURL, output.chaptersURL]
                        ) {
                            Label("Share video bundle", systemImage: "square.and.arrow.up")
                        }
                    } else if let errorText {
                        Label(errorText, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()
                .navigationTitle("Export Video")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(isExporting ? "Cancel" : "Done") { dismiss() }
                    }
                }
                .task { await runExport() }
            }
        }

        private func runExport() async {
            let outputDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "video-export-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: outputDirectory, withIntermediateDirectories: true)
                let result = try await VideoExportService().exportVideo(
                    audiobookID: audiobookID,
                    bookTitle: bookTitle,
                    databaseWriter: databaseWriter,
                    cacheDirectory: cacheDirectory,
                    outputDirectory: outputDirectory,
                    mode: .karaoke,
                    onProgress: { value in
                        Task { @MainActor in
                            fraction = value
                        }
                    })
                output = result
                isExporting = false
            } catch is CancellationError {
                // SwiftUI cancels the structured `.task` when the sheet is dismissed.
            } catch {
                errorText = error.localizedDescription
                isExporting = false
            }
        }
    }
#endif
