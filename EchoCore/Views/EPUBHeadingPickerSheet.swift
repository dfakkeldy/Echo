// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import GRDB

struct EPUBHeadingPickerSheet: View {
    let folderURL: URL
    let bookURL: URL
    let onSelect: (EPubBlockRecord) -> Void
    @Environment(PlayerModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var headings: [EPubBlockRecord] = []

    init(
        folderURL: URL,
        bookURL: URL? = nil,
        onSelect: @escaping (EPubBlockRecord) -> Void
    ) {
        self.folderURL = folderURL
        self.bookURL = bookURL ?? folderURL
        self.onSelect = onSelect
    }

    var body: some View {
        NavigationStack {
            List(headings) { heading in
                Button {
                    onSelect(heading)
                    dismiss()
                } label: {
                    HStack {
                        Text(heading.text ?? "Untitled Heading")
                            .font(.body)
                            .lineLimit(2)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Pick EPUB Heading")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                loadHeadings()
            }
        }
    }

    private func loadHeadings() {
        guard let db = model.databaseService else { return }
        let dao = EPubBlockDAO(db: db.writer)
        do {
            let blocks = try dao.blocks(for: bookURL.absoluteString)
            self.headings = blocks.filter { $0.blockKind == EPubBlockRecord.Kind.heading.rawValue && !($0.text?.isEmpty ?? true) }
        } catch {
            // Handle error silently
        }
    }
}
