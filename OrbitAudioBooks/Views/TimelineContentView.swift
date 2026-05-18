import SwiftUI

struct TimelineContentView: View {
    let service: TimelineService
    @Binding var isEditing: Bool
    var recenterTrigger: Int = 0

    var body: some View {
        if service.timelineMode == .playlistTime {
            PlaylistTimelineView(groups: service.groups)
        } else if service.groups.isEmpty {
            ContentUnavailableView(
                "No Events",
                systemImage: "clock.badge.questionmark",
                description: Text("Timeline events will appear here as you listen, create bookmarks, and review flashcards.")
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        // Load-earlier trigger
                        Color.clear
                            .frame(height: 1)
                            .onAppear {
                                service.loadEarlier()
                            }

                        ForEach(Array(service.groups.enumerated()), id: \.element.id) { index, group in
                            HStack(alignment: .top, spacing: 0) {
                                Text(service.timeScale.format(group.timestamp))
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

                            if let nowGroupID = nowGroupID, group.id == nowGroupID {
                                NowLineView()
                            }
                        }

                        Color.clear
                            .frame(height: 1)
                            .onAppear {
                                service.loadLater()
                            }
                    }
                    .padding(.vertical, 8)
                }
                .defaultScrollAnchor(.center)
                .onAppear {
                    if let id = nowGroupID ?? service.groups.first?.id {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
                .onChange(of: recenterTrigger) { _, _ in
                    if let id = nowGroupID {
                        withAnimation {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private var nowGroupID: String? {
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
