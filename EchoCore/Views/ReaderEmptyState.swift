// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct ReaderEmptyState: View {
    let hasLoadedBook: Bool
    let canAddEPUB: Bool
    let onImportBook: () -> Void
    let onAddEPUB: () -> Void

    init(
        hasLoadedBook: Bool = false,
        canAddEPUB: Bool = true,
        onImportBook: @escaping () -> Void = {},
        onAddEPUB: @escaping () -> Void = {}
    ) {
        self.hasLoadedBook = hasLoadedBook
        self.canAddEPUB = canAddEPUB
        self.onImportBook = onImportBook
        self.onAddEPUB = onAddEPUB
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "book.pages")
        } description: {
            Text(description)
        } actions: {
            if hasLoadedBook {
                Button("Add Document", systemImage: "plus") {
                    onAddEPUB()
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAddEPUB)
            } else {
                Button("Choose Book", systemImage: "folder") {
                    onImportBook()
                }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var title: String {
        hasLoadedBook ? "Add a Study Document" : "Start Reading"
    }

    private var description: String {
        if hasLoadedBook {
            "Add an EPUB for searchable text, or a PDF for page-based reading and alignment."
        } else {
            "Choose an audiobook, EPUB, or transcript to start reading and studying."
        }
    }
}
