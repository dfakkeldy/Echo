import SwiftUI

struct ReaderEmptyState: View {
    var body: some View {
        ContentUnavailableView(
            "No EPUB Available",
            systemImage: "book.pages",
            description: Text("Import an EPUB file alongside your audiobook to enable reading.")
        )
    }
}
