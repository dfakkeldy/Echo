import SwiftUI

struct UpcomingReviewsModuleView: View {
    @Environment(PlayerModel.self) private var model

    @State private var dueCount: Int = 0
    var onTap: (() -> Void)?

    var body: some View {
        Button {
            onTap?()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label("Reviews Due", systemImage: "rectangle.stack.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("\(dueCount)")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(dueCount > 0 ? .purple : .secondary)

                Text(dueCount == 0 ? "all caught up" : "tap to review")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(width: 120)
            .background(.purple.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .onAppear { loadDueCount() }
    }

    private func loadDueCount() {
        guard let db = model.databaseService else { return }
        do {
            let dao = FlashcardDAO(db: db.writer)
            dueCount = try dao.allDueCards().count
        } catch {
            dueCount = 0
        }
    }
}
