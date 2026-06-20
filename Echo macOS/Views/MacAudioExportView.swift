// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import SwiftUI
import UniformTypeIdentifiers

/// Exports the loaded book's narration to a chaptered `.m4b` via a save panel.
struct MacAudioExportView: View {
    let audiobookID: String
    let bookTitle: String
    let databaseWriter: DatabaseWriter

    @Environment(\.dismiss) private var dismiss
    @State private var isExporting = false
    @State private var savedPath = ""
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Export Audiobook").font(.title2)
            if isExporting {
                ProgressView("Exporting \(bookTitle).m4b…")
            } else if !savedPath.isEmpty {
                Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(savedPath).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            } else if let errorText {
                Label(errorText, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red).multilineTextAlignment(.center)
            }
            HStack {
                Button("Export…") { presentSavePanel() }.disabled(isExporting)
                Button("Done") { dismiss() }
            }
        }
        .padding().frame(width: 420, height: 220)
    }

    private func presentSavePanel() {
        errorText = nil
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Audiobook as .m4b")
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.nameFieldStringValue = "\(ExportFileName.safe(bookTitle)).m4b"
        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }
            Task {
                await MainActor.run { isExporting = true }
                do {
                    // Auto-detect narrated-vs-imported so File ▸ Export covers both.
                    let source = ExportSourceResolver.resolve(
                        audiobookID: audiobookID,
                        databaseWriter: databaseWriter,
                        cacheDirectory: NarrationCache.directory())
                    let items = try await source.items()
                    let meta = await ExportMetadataResolver.resolve(
                        audiobookID: audiobookID, fallbackTitle: bookTitle,
                        firstSourceURL: items.first?.url, databaseWriter: databaseWriter)
                    let temp = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4b")
                    defer { try? FileManager.default.removeItem(at: temp) }
                    try await AudioExportService().exportM4B(
                        items: items, outputURL: temp, metadata: meta)
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.copyItem(at: temp, to: dest)
                    await MainActor.run {
                        savedPath = dest.path(percentEncoded: false)
                        isExporting = false
                    }
                } catch {
                    await MainActor.run {
                        errorText = error.localizedDescription
                        isExporting = false
                    }
                }
            }
        }
    }
}
