import SwiftUI

struct UpcomingReviewsModuleView: View {
    @Environment(PlayerModel.self) private var model

    @State private var dueCount: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Reviews Due", systemImage: "rectangle.stack.fill")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("\(dueCount)")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(.purple)

            Text("flashcards")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 120)
        .background(.purple.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            loadDueCount()
        }
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
