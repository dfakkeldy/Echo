// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct LibraryShelfGrid: View {
    let sections: [LibrarySection]
    let statusMap: [String: LibraryBookStatus]
    let onTapBook: (AudiobookRecord) -> Void

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
                                    processing: statusMap[book.id]?.processing ?? []
                                ) {
                                    onTapBook(book)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .padding(.vertical)
        }
    }
}
