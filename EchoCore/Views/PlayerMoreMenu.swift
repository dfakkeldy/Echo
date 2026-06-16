// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// The player-scoped overflow menu, hosted in the Now Playing utility dock
/// (BottomToolbarView). Distinct from the app-level ellipsis menu in
/// `UnifiedTopHeader` (Stats / Fidget / Settings / Help): this one carries
/// *playback-context* actions — Chapters, Bookmarks, Sleep timer, Settings.
/// It uses a filled `ellipsis.circle.fill` glyph inside the dock's utility chip
/// to read as a clearly different overflow affordance than the global header's
/// bare `ellipsis`.
///
/// Sheet ownership note: this view raises sheets/tab-switches purely through
/// injected closures so the actual `.sheet` bindings live on the parent
/// (`NowPlayingTab`), never here — avoiding competing `.sheet(isPresented:)` bindings.
struct PlayerMoreMenu: View {
    @Environment(PlayerModel.self) private var model

    /// Present the chapter-navigation picker (parent owns the sheet binding).
    var onShowChapters: () -> Void
    /// Reveal the bookmarks list (parent switches to the Study/Timeline tab).
    var onShowBookmarks: () -> Void
    /// Raise the unified Settings sheet (parent owns the binding).
    var onShowSettings: () -> Void

    /// Active state mirrors the dock's other chips: filled when a sleep timer
    /// is armed, so the overflow chip carries a subtle "something is on" signal.
    private var isActive: Bool { model.sleepTimerMode.isActive }

    var body: some View {
        Menu {
            Button(action: onShowChapters) {
                Label("Chapters", systemImage: "list.bullet.indent")
            }
            .disabled(model.chapters.count < 2)

            Button(action: onShowBookmarks) {
                Label("Bookmarks", systemImage: "bookmark")
            }
            .disabled(model.tracks.isEmpty)

            Divider()

            Menu {
                Button {
                    model.setSleepTimer(.minutes(15))
                    Haptic.play(.light)
                } label: {
                    Label("15 Minutes", systemImage: "15.circle")
                }
                Button {
                    model.setSleepTimer(.minutes(30))
                    Haptic.play(.light)
                } label: {
                    Label("30 Minutes", systemImage: "30.circle")
                }
                Button {
                    model.setSleepTimer(.minutes(45))
                    Haptic.play(.light)
                } label: {
                    Label("45 Minutes", systemImage: "45.circle")
                }
                Button {
                    model.setSleepTimer(.minutes(60))
                    Haptic.play(.light)
                } label: {
                    Label("1 Hour", systemImage: "1.circle")
                }
                Divider()
                Button {
                    model.setSleepTimer(.endOfChapter)
                    Haptic.play(.light)
                } label: {
                    Label("End of Chapter", systemImage: "book.closed")
                }
                if model.sleepTimerMode.isActive {
                    Divider()
                    Button(role: .destructive) {
                        model.cancelSleepTimer()
                        Haptic.play(.light)
                    } label: {
                        Label("Off", systemImage: "xmark.circle")
                    }
                }
            } label: {
                Label("Sleep Timer", systemImage: "moon.zzz")
            }

            Divider()

            Button(action: onShowSettings) {
                Label("Settings", systemImage: "gearshape")
            }
        } label: {
            chip
        }
        .accessibilityLabel(Text("More playback options"))
    }

    /// The dock utility chip — a filled `ellipsis.circle.fill` to read as a
    /// clearly different overflow affordance than the global header's bare `ellipsis`.
    private var chip: some View {
        Image(systemName: "ellipsis.circle.fill")
            .font(.title2)
            .frame(width: 44, height: 44)
            .background(
                isActive ? AnyShapeStyle(model.coverTheme.chip) : AnyShapeStyle(.clear),
                in: Circle()
            )
            .contentShape(Rectangle())
            .foregroundStyle(
                isActive
                    ? AnyShapeStyle(model.artworkAccentColor ?? .accentColor)
                    : AnyShapeStyle(.secondary))
    }
}
