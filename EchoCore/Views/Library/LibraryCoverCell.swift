// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct LibraryCoverCell: View {
    let book: AudiobookRecord
    let processing: ProcessingStatus
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                LibraryCoverImage(coverArtPath: book.coverArtPath)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(alignment: .bottomTrailing) {
                        LibraryStatusDot(processing: processing)
                            .padding(5)
                    }
                    .overlay(alignment: .topLeading) {
                        if !book.isAvailable {
                            Text("Missing")
                                .font(.caption2)
                                .bold()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(.red, in: .capsule)
                                .padding(5)
                        }
                    }
                    .opacity(book.isAvailable ? 1 : 0.45)
                Text(book.title)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let author = book.author {
                    Text(author)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    private var accessibilityLabel: String {
        let availability = book.isAvailable ? "" : ", missing"
        if let author = book.author {
            return "\(book.title), \(author)\(availability)"
        }
        return "\(book.title)\(availability)"
    }
}
