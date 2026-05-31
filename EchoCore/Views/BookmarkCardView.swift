import SwiftUI

struct BookmarkCardView: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Bookmarks", systemImage: "bookmark")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(countLabel)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(model.bookmarks.isEmpty ? .secondary : Color.yellow)

            Text("in this book")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 120)
        .background(.yellow.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var countLabel: String {
        let count = model.bookmarks.count
        return count == 0 ? "—" : "\(count)"
    }
}
