// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct UpcomingReviewsModuleView: View {
    @Environment(PlayerModel.self) private var model
    @ScaledMetric(relativeTo: .body) private var cardWidth: CGFloat = 140

    @State private var queueCount: Int = 0
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

                Text("\(queueCount)")
                    .font(.title2)
                    .bold()
                    .foregroundStyle(queueCount > 0 ? .purple : .secondary)

                if reviewedToday > 0 {
                    Text("^[\(reviewedToday) reviewed today](inflect: true)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text(queueCount == 0 ? "all caught up" : "tap to study")
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
        .onReceive(NotificationCenter.default.publisher(for: .studyPlanDidChange)) { _ in
            loadStats()
        }
        .onReceive(NotificationCenter.default.publisher(for: .studyQueueDidChange)) { _ in
            loadStats()
        }
    }

    private func loadStats() {
        guard let db = model.databaseService else { return }
        do {
            let stats = try FlashcardDAO(db: db.writer).reviewStats()
            let queue = try StudyQueueBuilder(db: db.writer).build(
                globalNewChapterLimit: model.settingsManager?.studyGlobalNewChapterLimit
                    ?? SettingsManager.Defaults.studyGlobalNewChapterLimit
            )
            queueCount = queue.totalCount
            reviewedToday = stats.reviewedToday
            ReviewNotificationService.updateNotification(
                dueCount: queue.dueReviewCount + queue.inProgressAssignmentCount,
                isEnabled: model.settingsManager?.reviewNotificationsEnabled ?? false
            )
        } catch {
            queueCount = 0
            reviewedToday = 0
        }
    }
}
