import SwiftUI

struct PlaylistTimelineView: View {
    @Environment(PlayerModel.self) private var model
    let groups: [TimelineGroup]

    private var totalDuration: TimeInterval {
        model.chapters.last?.endSeconds ?? model.durationSeconds ?? 0
    }

    var body: some View {
        if model.chapters.isEmpty && model.tracks.isEmpty {
            ContentUnavailableView(
                "No Content",
                systemImage: "music.note.list",
                description: Text("Open a folder or audiobook to see its chapters and content on the playlist timeline.")
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Chapter blocks
                    ForEach(Array(model.chapters.enumerated()), id: \.offset) { index, chapter in
                        ChapterTimeBlockView(
                            title: chapter.title ?? "",
                            chapterIndex: index,
                            chapterCount: model.chapters.count,
                            startSeconds: chapter.startSeconds,
                            durationSeconds: chapter.endSeconds - chapter.startSeconds,
                            totalBookDuration: totalDuration,
                            isCurrentChapter: model.currentChapterIndex == index,
                            isPlayed: chapter.endSeconds < model.currentPlaybackTime
                        )
                        .padding(.vertical, 4)
                        .padding(.horizontal, 16)

                        // Overlaid cards for this chapter's time range
                        let chapterCards = cards(in: chapter.startSeconds...chapter.endSeconds)
                        if !chapterCards.isEmpty {
                            ForEach(chapterCards) { card in
                                TimelineContentCard(card: card, isEditing: false)
                                    .padding(.leading, 32)
                                    .padding(.horizontal, 16)
                            }
                        }
                    }

                    // Bookmarks and notes that fall outside any chapter
                    let unmatchedCards = cardsOutsideChapters()
                    if !unmatchedCards.isEmpty {
                        Divider().padding(.vertical, 8)
                        ForEach(unmatchedCards) { card in
                            TimelineContentCard(card: card, isEditing: false)
                                .padding(.horizontal, 16)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private func cards(in range: ClosedRange<TimeInterval>) -> [ContentCard] {
        groups.flatMap { group in
            group.cards.filter { card in
                guard let mt = card.mediaTimestamp else { return false }
                return range.contains(mt)
            }
        }
    }

    private func cardsOutsideChapters() -> [ContentCard] {
        let chapterRanges = model.chapters.map { $0.startSeconds...$0.endSeconds }
        return groups.flatMap { group in
            group.cards.filter { card in
                guard let mt = card.mediaTimestamp else { return false }
                return !chapterRanges.contains { $0.contains(mt) }
            }
        }
    }
}
