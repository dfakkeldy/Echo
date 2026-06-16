// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct UpcomingReviewsModuleView: View {
    @Environment(PlayerModel.self) private var model
    @ScaledMetric(relativeTo: .body) private var cardWidth: CGFloat = 140

    @State private var dueCount: Int = 0
    @State private var reviewedToday: Int = 0
    var onTap: (() -> Void)?

    var body: some View {
        Button {
            onTap?()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label("Reviews", systemImage: "rectangle.stack.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("\(dueCount)")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(dueCount > 0 ? .purple : .secondary)

                if reviewedToday > 0 {
                    Text("^[\(reviewedToday) reviewed today](inflect: true)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text(dueCount == 0 ? "all caught up" : "tap to review")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(width: cardWidth)
            .background(.purple.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .onAppear { loadStats() }
    }

    private func loadStats() {
        guard let db = model.databaseService else { return }
        do {
            let dao = FlashcardDAO(db: db.writer)
            let stats = try dao.reviewStats()
            dueCount = stats.dueCount
            reviewedToday = stats.reviewedToday
            ReviewNotificationService.updateNotification(dueCount: stats.dueCount)
        } catch {
            dueCount = 0
            reviewedToday = 0
        }
    }
}
