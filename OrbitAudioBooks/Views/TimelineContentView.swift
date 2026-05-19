import SwiftUI

/// Real-time (calendar) timeline content — event groups with "Now" line.
/// Used by the Planner tab. Owns its TimelineService internally.
struct TimelineContentView: View {
    @Environment(PlayerModel.self) private var model
    @Binding var isEditing: Bool
    let timeScale: TimelineScope
    var recenterTrigger: Int = 0

    @State private var realTimeService: TimelineService?

    var body: some View {
        Group {
            if let realTimeService, !realTimeService.groups.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            Color.clear
                                .frame(height: 1)
                                .onAppear { realTimeService.loadEarlier() }

                            ForEach(Array(realTimeService.groups.enumerated()), id: \.element.id) { index, group in
                                HStack(alignment: .top, spacing: 0) {
                                    Text(realTimeService.timeScale.format(group.timestamp))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 64, alignment: .trailing)
                                        .padding(.trailing, 8)
                                        .padding(.top, 6)

                                    VStack(spacing: 4) {
                                        ForEach(group.cards) { card in
                                            TimelineContentCard(card: card, isEditing: isEditing)
                                        }
                                    }

                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 3)
                                .id(group.id)

                                if let nowGroupID = nowGroupID(service: realTimeService), group.id == nowGroupID {
                                    NowLineView()
                                }
                            }

                            Color.clear
                                .frame(height: 1)
                                .onAppear { realTimeService.loadLater() }
                        }
                        .padding(.vertical, 8)
                    }
                    .defaultScrollAnchor(.center)
                    .onAppear {
                        if let id = nowGroupID(service: realTimeService) ?? realTimeService.groups.first?.id {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                    .onChange(of: recenterTrigger) { _, _ in
                        realTimeService.recenterOnNow()
                        if let id = nowGroupID(service: realTimeService) {
                            withAnimation { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Events",
                    systemImage: "clock.badge.questionmark",
                    description: Text("Timeline events will appear here as you listen, create bookmarks, and review flashcards.")
                )
            }
        }
        .onAppear {
            if realTimeService == nil, let db = model.databaseService {
                let ts = TimelineService(databaseService: db)
                ts.recenterOnNow()
                realTimeService = ts
            }
        }
        .onChange(of: timeScale) { _, new in
            realTimeService?.setTimeScale(new)
        }
        .onChange(of: recenterTrigger) { _, _ in
            realTimeService?.recenterOnNow()
        }
    }

    private func nowGroupID(service: TimelineService) -> String? {
        guard let first = service.groups.first else { return nil }
        let now = service.now
        var best = first
        var bestDelta = abs(best.timestamp.timeIntervalSince(now))
        for group in service.groups {
            let delta = abs(group.timestamp.timeIntervalSince(now))
            if delta < bestDelta {
                bestDelta = delta
                best = group
            }
        }
        return best.id
    }
}
