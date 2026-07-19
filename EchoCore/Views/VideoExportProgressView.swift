// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS)
    import GRDB
    import SwiftUI
    import UIKit

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
                            Text(.videoExportProgressTitle)
                        }
                        .accessibilityValue(
                            Text(fraction, format: .percent.precision(.fractionLength(0))))

                        Text(.videoExportProgressMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if let output {
                        Label(.videoExportComplete, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        ShareLink(
                            items: [output.videoURL, output.srtURL, output.chaptersURL]
                        ) {
                            Label(.videoExportShareBundle, systemImage: "square.and.arrow.up")
                        }
                    } else if let errorText {
                        Label(errorText, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()
                .navigationTitle(Text(.videoExportTitle))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            dismiss()
                        } label: {
                            Text(isExporting ? .cancel : .done)
                        }
                    }
                }
                .task { await runExport() }
            }
        }

        private func runExport() async {
            let outputDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "video-export-\(UUID().uuidString)", isDirectory: true)
            let (progressStream, progressContinuation) = AsyncStream.makeStream(
                of: Double.self,
                bufferingPolicy: .bufferingNewest(1))
            let progressConsumer = Task {
                for await value in progressStream {
                    fraction = value
                }
            }
            let backgroundTask = VideoExportBackgroundTask()
            var shouldPreserveOutput = false

            backgroundTask.begin()
            defer {
                progressContinuation.finish()
                progressConsumer.cancel()
                backgroundTask.end()
                if !shouldPreserveOutput {
                    try? FileManager.default.removeItem(at: outputDirectory)
                }
            }

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
                    dimensions: .landscape,
                    onProgress: { value in
                        progressContinuation.yield(value)
                    })
                progressContinuation.finish()
                await progressConsumer.value
                output = result
                shouldPreserveOutput = true
                isExporting = false
            } catch is CancellationError {
                // SwiftUI cancels the structured `.task` when the sheet is dismissed.
            } catch {
                errorText = exportErrorText(for: error)
                isExporting = false
            }
        }

        private func exportErrorText(for error: Error) -> String {
            guard let exportError = error as? VideoExportService.ExportError else {
                return error.localizedDescription
            }

            switch exportError {
            case .noAudio:
                return String(localized: .videoExportErrorNoAudio)
            case .noAlignment:
                return String(localized: .videoExportErrorNoAlignment)
            case .writerFailed:
                return String(localized: .videoExportErrorWriterFailed)
            case .unsupportedVideoSettings(let width, let height):
                let size =
                    "\(width.formatted(.number.grouping(.never)))"
                    + " × \(height.formatted(.number.grouping(.never)))"
                return
                    "\(String(localized: .videoExportErrorUnsupportedVideoSettings)) (\(size))"
            }
        }
    }

    @MainActor
    private final class VideoExportBackgroundTask {
        private var identifier: UIBackgroundTaskIdentifier = .invalid

        func begin() {
            guard identifier == .invalid else { return }
            identifier = UIApplication.shared.beginBackgroundTask(
                withName: "Echo slideshow video export",
                expirationHandler: { [weak self] in
                    self?.end()
                })
        }

        func end() {
            guard identifier != .invalid else { return }
            let activeIdentifier = identifier
            identifier = .invalid
            UIApplication.shared.endBackgroundTask(activeIdentifier)
        }
    }
#endif
