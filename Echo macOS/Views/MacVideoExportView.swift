// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

/// Exports the loaded book's Visual Listening slideshow as an MP4, SRT, and
/// chapter-list bundle through a macOS save panel.
struct MacVideoExportView: View {
    let audiobookID: String
    let bookTitle: String
    let databaseWriter: DatabaseWriter
    /// Injected, not read from `@Environment` — see `MacArticleWorkshopView`:
    /// sheet content does not see the `.environment(...)` writes applied to the
    /// window root, so an environment read here trapped on open.
    let settings: SettingsManager

    @Environment(\.dismiss) private var dismiss

    @State private var isExporting = false
    @State private var fraction = 0.0
    @State private var output: VideoExportService.Output?
    @State private var errorText: String?
    @State private var exportTask: Task<Void, Never>?
    @State private var mode: SlideshowExportMode = .karaoke
    @State private var selectedFormat: SlideshowVideoFormat = .landscape

    /// An immutable snapshot of the mode/format @State, captured at the start
    /// of `presentSavePanel()` before `NSSavePanel` is even constructed. The
    /// panel completion and the export `Task` read only this value -- never
    /// the mutable `mode`/`selectedFormat` @State -- so changing a picker
    /// while the save panel sheet is open can never race the export.
    private struct MacVideoExportConfiguration: Sendable {
        let mode: SlideshowExportMode
        let dimensions: SlideshowVideoDimensions
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(.videoExportTitle)
                .font(.title2)

            Picker(String(localized: .videoExportModeLabel), selection: $mode) {
                Text(.videoExportModeKaraoke).tag(SlideshowExportMode.karaoke)
                Text(.videoExportModeSimple).tag(SlideshowExportMode.simple)
            }
            .pickerStyle(.segmented)
            .disabled(isExporting)

            // macOS keeps BOTH the Karaoke/Simple mode picker above and this
            // Landscape/Portrait format picker -- unlike iPhone v1, which is
            // Karaoke-only. Both default values are visible before the save
            // panel and both freeze while an export is active.
            SlideshowVideoFormatPicker(selection: $selectedFormat)
                .disabled(isExporting)

            if isExporting {
                ProgressView(value: fraction) {
                    Text(.videoExportProgressTitle)
                }
                .accessibilityValue(
                    Text(fraction, format: .percent.precision(.fractionLength(0))))

                Text(.videoExportProgressMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if let output {
                Label(.videoExportComplete, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(output.videoURL.path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button(.videoExportRevealInFinder) {
                    NSWorkspace.shared.activateFileViewerSelecting([output.videoURL])
                }
            } else if let errorText {
                Label(errorText, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            HStack {
                if !isExporting {
                    Button(.videoExportChooseDestination) {
                        presentSavePanel()
                    }
                }

                Button {
                    if isExporting {
                        exportTask?.cancel()
                    } else {
                        dismiss()
                    }
                } label: {
                    Text(isExporting ? .cancel : .done)
                }
            }
        }
        .padding()
        .frame(minWidth: 460, minHeight: 320)
        .onDisappear { exportTask?.cancel() }
    }

    /// The mode + format configuration is settled BEFORE the save panel is
    /// presented -- captured as the very first statement, before `NSSavePanel`
    /// is constructed or shown -- and the panel callback only begins export
    /// work. This preserves the sibling audio export's sequencing rule: never
    /// present a SwiftUI sheet from inside the `NSSavePanel` callback, and it
    /// additionally prevents a race where the user changes a picker while the
    /// save panel is open.
    private func presentSavePanel() {
        let configuration = MacVideoExportConfiguration(
            mode: mode, dimensions: selectedFormat.dimensions)

        errorText = nil
        output = nil
        let panel = NSSavePanel()
        panel.title = String(localized: .videoExportSavePanelTitle)
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "\(bookTitle).mp4"
        panel.begin { response in
            guard response == .OK, let panelURL = panel.url else { return }
            startExport(to: panelURL, configuration: configuration)
        }
    }

    private func startExport(to panelURL: URL, configuration: MacVideoExportConfiguration) {
        let preferredVoice =
            settings.narrationVoiceID.isEmpty
            ? VoiceCatalog.default.id : VoiceID(settings.narrationVoiceID)
        fraction = 0
        output = nil
        errorText = nil
        isExporting = true

        exportTask = Task {
            var stagingDirectoryToRemove: URL?
            let (progressStream, progressContinuation) = AsyncStream.makeStream(
                of: Double.self,
                bufferingPolicy: .bufferingNewest(1))
            let progressConsumer = Task {
                for await value in progressStream {
                    fraction = min(max(value, 0), 1)
                }
            }

            defer {
                panelURL.stopAccessingSecurityScopedResource()
                progressContinuation.finish()
                progressConsumer.cancel()
                if let stagingDirectory = stagingDirectoryToRemove {
                    try? FileManager.default.removeItem(at: stagingDirectory)
                }
                exportTask = nil
            }

            do {
                let destination = try VideoExportDestination(panelURL: panelURL)
                let stagingDirectory = try MacVideoExportPublisher.makeStagingDirectory()
                stagingDirectoryToRemove = stagingDirectory
                let stagedOutput = try await VideoExportService().exportVideo(
                    audiobookID: audiobookID,
                    bookTitle: bookTitle,
                    databaseWriter: databaseWriter,
                    cacheDirectory: NarrationCache.directory(),
                    preferredVoice: preferredVoice,
                    outputDirectory: stagingDirectory,
                    mode: configuration.mode,
                    dimensions: configuration.dimensions,
                    onProgress: { value in
                        progressContinuation.yield(value)
                    })
                progressContinuation.finish()
                await progressConsumer.value
                try Task.checkCancellation()
                let publicationWorker = Task.detached(priority: .userInitiated) {
                    try MacVideoExportPublisher.publish(
                        stagedOutput: stagedOutput,
                        to: destination)
                }
                let publishedOutput = try await withTaskCancellationHandler {
                    try await publicationWorker.value
                } onCancel: {
                    publicationWorker.cancel()
                }
                output = publishedOutput
                isExporting = false
            } catch is CancellationError {
                fraction = 0
                isExporting = false
            } catch {
                errorText = exportErrorText(for: error)
                isExporting = false
            }
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
            return "\(String(localized: .videoExportErrorUnsupportedVideoSettings)) (\(size))"
        }
    }
}
