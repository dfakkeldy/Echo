// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct NowPlayingEmptyState: View {
    let onChooseBook: () -> Void
    let onOpenHelp: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Book Open", systemImage: "book.closed")
        } description: {
            Text("Choose an audiobook, EPUB, or transcript to start listening and studying.")
        } actions: {
            Button("Choose Book", systemImage: "folder") {
                onChooseBook()
            }
            .buttonStyle(.borderedProminent)

            Button("Help", systemImage: "questionmark.circle") {
                onOpenHelp()
            }
            .buttonStyle(.bordered)
        }
    }
}
