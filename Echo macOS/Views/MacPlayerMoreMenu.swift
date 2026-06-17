// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// The "More" menu for the macOS player bar: chapter navigation, bookmark
/// jump/add, mark-passage, the sleep timer, and Settings. Mirrors the iOS
/// PlayerMoreMenu using the existing MacPlayerModel API. `onMarkPassage` is
/// injected because passage insertion needs the DatabaseService (owned by
/// MacTriPaneView), not the player model.
struct MacPlayerMoreMenu: View {
    @Environment(MacPlayerModel.self) private var player

    var onMarkPassage: () -> Void

    var body: some View {
        Menu {
            chaptersSection
            bookmarksSection

            Divider()

            Button {
                _ = player.addBookmarkAtCurrentTime()
            } label: {
                Label("Add Bookmark", systemImage: "bookmark")
            }
            .disabled(!player.hasMedia)

            Button {
                onMarkPassage()
            } label: {
                Label("Mark Passage", systemImage: "text.badge.star")
            }
            .disabled(!player.hasMedia)

            Divider()

            sleepSection

            Divider()

            SettingsLink {
                Label("Settings…", systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .help("More")
        .frame(width: 28)
    }

    @ViewBuilder
    private var chaptersSection: some View {
        if player.chapters.count >= 2 {
            Menu {
                ForEach(Array(player.chapters.enumerated()), id: \.element.id) { index, chapter in
                    Button {
                        player.seekToChapter(index)
                    } label: {
                        if index == player.currentChapterIndex {
                            Label(chapterTitle(chapter, at: index), systemImage: "checkmark")
                        } else {
                            Text(chapterTitle(chapter, at: index))
                        }
                    }
                }
            } label: {
                Label("Chapters", systemImage: "list.bullet")
            }
        }
    }

    private func chapterTitle(_ chapter: Chapter, at index: Int) -> String {
        if let title = chapter.title, !title.isEmpty {
            return title
        }
        return String(localized: "Chapter \(index + 1)")
    }

    @ViewBuilder
    private var bookmarksSection: some View {
        let bookmarks = player.bookmarkStore.bookmarks
        if bookmarks.isEmpty {
            Button {
            } label: {
                Label("No Bookmarks", systemImage: "bookmark.slash")
            }
            .disabled(true)
        } else {
            Menu {
                ForEach(bookmarks) { bookmark in
                    Button {
                        player.jumpTo(bookmark)
                    } label: {
                        Text("\(bookmark.title) — \(formatHMS(bookmark.timestamp))")
                    }
                }
            } label: {
                Label("Bookmarks", systemImage: "bookmark.fill")
            }
        }
    }

    @ViewBuilder
    private var sleepSection: some View {
        Menu {
            Button("Off") { player.sleepTimerMode = .off }
            Divider()
            Button("5 min") { player.sleepTimerMode = .minutes(5) }
            Button("10 min") { player.sleepTimerMode = .minutes(10) }
            Button("15 min") { player.sleepTimerMode = .minutes(15) }
            Button("30 min") { player.sleepTimerMode = .minutes(30) }
            Button("45 min") { player.sleepTimerMode = .minutes(45) }
            Button("60 min") { player.sleepTimerMode = .minutes(60) }
            Divider()
            Button("End of Chapter") { player.sleepTimerMode = .endOfChapter }
        } label: {
            Label(
                "Sleep Timer",
                systemImage: player.sleepTimer.mode == .off ? "moon.zzz" : "moon.zzz.fill"
            )
        }
    }
}
