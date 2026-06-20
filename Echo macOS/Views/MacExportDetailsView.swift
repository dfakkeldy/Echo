// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers

/// Pre-filled confirm step (macOS), shown only when author or cover is missing.
struct MacExportDetailsView: View {
    @State var metadata: ExportMetadata
    let onConfirm: (ExportMetadata) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Details").font(.title2)
            TextField("Title", text: $metadata.title)
            TextField(
                "Author",
                text: Binding(
                    get: { metadata.author ?? "" }, set: { metadata.author = $0 }))
            HStack {
                if let data = metadata.coverArt, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFit().frame(height: 80)
                }
                Button("Choose cover…") { chooseCover() }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Export") {
                    onConfirm(metadata)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding().frame(width: 420)
    }

    private func chooseCover() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
            metadata.coverArt = data
        }
    }
}
