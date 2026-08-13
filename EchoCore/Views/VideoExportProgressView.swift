// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS)
    import GRDB
    import SwiftUI
    import UIKit

    /// Exports the loaded book's Visual Listening slideshow as an MP4, SRT, and
    /// chapter-list bundle through a three-phase flow: **Configuration** (pick a
    /// format), **Export** (progress), and **Result** (share or error).
    ///
    /// The sheet no longer auto-starts on appearance. The Export button captures
    /// one immutable `VideoExportRequest`, and a `.task(id:)` keyed by that
    /// request owns the structured export task, so dismissing the sheet
    /// cooperatively cancels `VideoExportService` without a detached task. A
    /// second export cannot begin until the view reaches `.result` or is
    /// recreated.
    struct VideoExportProgressView: View {
        let audiobookID: String
        let bookTitle: String
        let cacheDirectory: URL
        let databaseWriter: DatabaseWriter

        @Environment(\.dismiss) private var dismiss
        @Environment(SettingsManager.self) private var settings

        /// The immutable, structured-concurrency-safe unit of export work. Its
        /// unique `id` keys the `.task(id:)`, and its validated `dimensions`
        /// cannot change once captured.
        private struct VideoExportRequest: Identifiable, Equatable {
            let id = UUID()
            let dimensions: SlideshowVideoDimensions
        }

        private enum VideoExportPhase {
            case configuration
            case exporting(VideoExportRequest)
            case result
        }

        @State private var phase: VideoExportPhase = .configuration
        @State private var selectedFormat: SlideshowVideoFormat = .landscape
        @State private var request: VideoExportRequest?
        @State private var fraction = 0.0
        @State private var output: VideoExportService.Output?
        @State private var errorText: String?

        private var isResult: Bool {
            if case .result = phase { return true }
            return false
        }

        var body: some View {
            NavigationStack {
                content
                    .padding()
                    .navigationTitle(Text(.videoExportTitle))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button {
                                dismiss()
                            } label: {
                                // Configuration and export show Cancel (dismiss
                                // closes or cancels); only the result shows Done.
                                Text(isResult ? .done : .cancel)
                            }
                        }
                    }
                    // Keyed by the captured request's id: nil until Export is
                    // tapped, so SwiftUI starts the task only on capture and
                    // cancels it when the sheet disappears. No detached task.
                    .task(id: request?.id) {
                        guard let request else { return }
                        await runExport(request)
                    }
            }
        }

        @ViewBuilder
        private var content: some View {
            switch phase {
            case .configuration:
                configuration
            case .exporting:
                exporting
            case .result:
                result
            }
        }

        private var configuration: some View {
            // A ScrollView keeps the picker, resolution, explanatory copy, and
            // Export button reachable at the largest Dynamic Type sizes and on
            // the smallest supported iPhone.
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // iPhone v1 uses Karaoke implicitly; the only choice offered
                    // is Landscape vs Portrait via the shared picker, which also
                    // renders the exact dimensions and phone-viewing copy.
                    SlideshowVideoFormatPicker(selection: $selectedFormat)

                    Button {
                        // Capture exactly one immutable request and transition
                        // immediately; `request != nil` then disables the button
                        // so a second export cannot begin until Result/recreation.
                        let newRequest = VideoExportRequest(
                            dimensions: selectedFormat.dimensions)
                        request = newRequest
                        phase = .exporting(newRequest)
                    } label: {
                        Text(.videoExportConfigurationExportButton)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(request != nil)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        private var exporting: some View {
            VStack(spacing: 20) {
                ProgressView(value: fraction) {
                    Text(.videoExportProgressTitle)
                }
                .accessibilityValue(
                    Text(fraction, format: .percent.precision(.fractionLength(0))))

                Text(.videoExportProgressMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        @ViewBuilder
        private var result: some View {
            VStack(spacing: 20) {
                if let output {
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
        }

        private func runExport(_ request: VideoExportRequest) async {
            let preferredVoice =
                settings.narrationVoiceID.isEmpty
                ? VoiceCatalog.default.id : VoiceID(settings.narrationVoiceID)
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
                    preferredVoice: preferredVoice,
                    outputDirectory: outputDirectory,
                    mode: .karaoke,
                    dimensions: request.dimensions,
                    onProgress: { value in
                        progressContinuation.yield(value)
                    })
                progressContinuation.finish()
                await progressConsumer.value
                output = result
                shouldPreserveOutput = true
                phase = .result
            } catch is CancellationError {
                // SwiftUI cancels the structured `.task` when the sheet is dismissed.
            } catch {
                errorText = exportErrorText(for: error)
                phase = .result
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
                // Interpolate the requested pixels via `FormatStyle`, never
                // C-style printf formatting, so the actionable copy stays
                // localized and grouping-safe.
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
