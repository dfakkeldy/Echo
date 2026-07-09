// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct LibraryShelfGrid: View {
    let sections: [LibrarySection]
    let statusMap: [String: LibraryBookStatus]
    let siblingEditions: (AudiobookRecord) -> [AudiobookRecord]
    let onTapBook: (AudiobookRecord) -> Void
    let onSeparateEdition: (AudiobookRecord) -> Void

    private let columns = [GridItem(.adaptive(minimum: 112), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(sections, id: \.title) { section in
                    if !section.books.isEmpty {
                        Text(section.title)
                            .font(.headline)
                            .padding(.horizontal)
                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(section.books, id: \.id) { book in
                                LibraryCoverCell(
                                    book: book,
                                    processing: statusMap[book.id]?.processing ?? [],
                                    siblingEditions: siblingEditions(book)
                                ) {
                                    onTapBook(book)
                                } onSelectEdition: { edition in
                                    onTapBook(edition)
                                } onSeparateEdition: {
                                    onSeparateEdition(book)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .padding(.vertical)
        }
        // Reserve room for Row 1 of UnifiedTopHeader (overlaid in RootTabView) so the
        // first shelf header isn't hidden under the floating folder chip. Same pattern
        // as NowPlayingTab/ReaderTab; lives here (not on LibraryView's Group) so the
        // empty state's manual padding isn't doubled.
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: UnifiedTopHeader.rowOneHeight)
        }
    }
}
