// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS)
    import PhotosUI
    import SwiftUI

    /// Pre-filled "confirm details" step shown only when author or cover is
    /// missing. Returns the (possibly edited) metadata to the caller's `onConfirm`.
    struct ExportDetailsSheet: View {
        @State var metadata: ExportMetadata
        let onConfirm: (ExportMetadata) -> Void
        @Environment(\.dismiss) private var dismiss
        @State private var pickerItem: PhotosPickerItem?

        var body: some View {
            NavigationStack {
                Form {
                    Section("Title") {
                        TextField("Title", text: $metadata.title)
                    }
                    Section("Author") {
                        TextField(
                            "Author",
                            text: Binding(
                                get: { metadata.author ?? "" },
                                set: { metadata.author = $0 }))
                    }
                    Section("Cover") {
                        if let data = metadata.coverArt, let image = UIImage(data: data) {
                            Image(uiImage: image).resizable().scaledToFit().frame(height: 120)
                        }
                        PhotosPicker("Choose cover…", selection: $pickerItem, matching: .images)
                    }
                }
                .navigationTitle("Export Details")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Export") {
                            onConfirm(metadata)
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { dismiss() }
                    }
                }
                .task(id: pickerItem) {
                    if let data = try? await pickerItem?.loadTransferable(type: Data.self) {
                        metadata.coverArt = data
                    }
                }
            }
        }
    }
#endif
