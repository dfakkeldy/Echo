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

    @Environment(\.dismiss) private var dismiss

    @State private var isExporting = false
    @State private var fraction = 0.0
    @State private var output: VideoExportService.Output?
    @State private var errorText: String?
    @State private var exportTask: Task<Void, Never>?
    @State private var mode: SlideshowExportMode = .karaoke

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
        .frame(width: 460, height: 300)
        .onDisappear { exportTask?.cancel() }
    }

    /// The render mode is settled BEFORE the save panel is presented, and the
    /// panel callback only begins export work. This preserves the sibling audio
    /// export's sequencing rule: never present a SwiftUI sheet from inside the
    /// `NSSavePanel` callback.
    private func presentSavePanel() {
        errorText = nil
        output = nil
        let panel = NSSavePanel()
        panel.title = String(localized: .videoExportSavePanelTitle)
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "\(bookTitle).mp4"
        panel.begin { response in
            guard response == .OK, let panelURL = panel.url else { return }
            startExport(to: panelURL)
        }
    }

    private func startExport(to panelURL: URL) {
        fraction = 0
        output = nil
        errorText = nil
        isExporting = true

        exportTask = Task {
            let didStartAccessing = panelURL.startAccessingSecurityScopedResource()
            let outputBaseName = panelURL.deletingPathExtension().lastPathComponent
            let (progressStream, progressContinuation) = AsyncStream.makeStream(
                of: Double.self,
                bufferingPolicy: .bufferingNewest(1))
            let progressConsumer = Task {
                for await value in progressStream {
                    fraction = min(max(value, 0), 1)
                }
            }

            defer {
                progressContinuation.finish()
                progressConsumer.cancel()
                if didStartAccessing {
                    panelURL.stopAccessingSecurityScopedResource()
                }
                exportTask = nil
            }

            do {
                let result = try await VideoExportService().exportVideo(
                    audiobookID: audiobookID,
                    bookTitle: outputBaseName,
                    databaseWriter: databaseWriter,
                    cacheDirectory: NarrationCache.directory(),
                    outputDirectory: panelURL.deletingLastPathComponent(),
                    mode: mode,
                    onProgress: { value in
                        progressContinuation.yield(value)
                    })
                progressContinuation.finish()
                await progressConsumer.value
                output = result
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
        }
    }
}
