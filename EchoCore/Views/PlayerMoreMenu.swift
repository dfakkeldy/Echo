// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

enum PlayerMoreMenuState {
    static func timerAccessibilityValue(
        showsReaderSleepTimer: Bool,
        mode: SleepTimerMode,
        remainingSeconds: Int
    ) -> String? {
        guard showsReaderSleepTimer, mode.isActive else { return nil }
        return SleepTimerPillState.accessibilityValue(
            mode: mode,
            remainingSeconds: remainingSeconds
        )
    }
}

/// The single overflow menu, hosted in the root-owned utility dock
/// (`BottomToolbarView`). It carries playback-context actions and app-level
/// actions that used to live in `UnifiedTopHeader`, keeping one predictable
/// "More" surface for the player UI.
///
/// Sheet ownership note: this view raises sheets/tab-switches purely through
/// injected closures so the actual `.sheet` bindings live on the parent
/// (`RootTabView`), never here — avoiding competing `.sheet(isPresented:)` bindings.
struct PlayerMoreMenu: View {
    @Environment(PlayerModel.self) private var model

    /// Present the chapter-navigation picker (parent owns the sheet binding).
    var onShowChapters: () -> Void
    /// Reveal the bookmarks list (parent switches tab).
    var onShowBookmarks: () -> Void
    // App-level actions relocated from the deleted UnifiedTopHeader ellipsis
    // menu (2026-07-05 chrome consolidation): one overflow menu for the app.
    var onStats: () -> Void
    var onFidget: () -> Void
    var onSettings: () -> Void
    var onHelp: () -> Void
    /// `nil` when no book is loaded or narration is rendering (item hidden).
    var onAddDocument: (() -> Void)?
    var onExport: (() -> Void)?
    var onVideoExport: (() -> Void)?
    var onStudyNotesExport: (() -> Void)?
    var onOpenBookOrFolder: (() -> Void)? = nil
    var showsReaderSleepTimer = false
    /// Experimental player only: enter edit-button mode. `nil` outside the player.
    var onEditLayout: (() -> Void)? = nil

    var body: some View {
        Menu {
            if let onEditLayout {
                Button("Edit Buttons…", systemImage: "slider.horizontal.3", action: onEditLayout)
                Divider()
            }
            // Playback context
            Button(action: onShowChapters) {
                Label("Chapters", systemImage: "list.bullet.indent")
            }
            .disabled(model.chapters.count < 2)

            Button(action: onShowBookmarks) {
                Label("Bookmarks", systemImage: "bookmark")
            }
            .disabled(model.tracks.isEmpty)

            Divider()

            // Current book
            if let onAddDocument {
                Button(action: onAddDocument) {
                    Label(
                        model.hasEPUB || model.hasPDF
                            ? "Replace Document…" : "Add Document…",
                        systemImage: "book.pages"
                    )
                }
            }
            if let onOpenBookOrFolder {
                Button(action: onOpenBookOrFolder) {
                    Label("Open Book or Folder…", systemImage: "folder")
                }
            }
            if showsReaderSleepTimer {
                Menu {
                    SleepTimerMenuContent(showsActiveStatus: true)
                } label: {
                    Label(
                        "Sleep Timer",
                        systemImage: model.sleepTimerMode.isActive ? "moon.zzz.fill" : "moon.zzz"
                    )
                }
            }
            if let onExport {
                Button(action: onExport) {
                    Label("Export Audiobook (.m4b)…", systemImage: "square.and.arrow.up")
                }
            }
            if let onVideoExport {
                Button(action: onVideoExport) {
                    Label(.videoExportMenuTitle, systemImage: "film")
                }
            }
            if let onStudyNotesExport {
                Button(action: onStudyNotesExport) {
                    Label("Export Study Notes…", systemImage: "doc.text")
                }
            }

            Divider()

            // App level
            Button(action: onStats) {
                Label("Stats", systemImage: "chart.bar.fill")
            }
            Button(action: onFidget) {
                Label("Fidget", systemImage: "circle.hexagongrid.fill")
            }
            .disabled(model.tracks.isEmpty)
            Button(action: onSettings) {
                Label("Settings", systemImage: "gearshape")
            }
            Button(action: onHelp) {
                Label("Help", systemImage: "questionmark.circle")
            }
        } label: {
            chip
        }
    }

    @ViewBuilder
    private var chip: some View {
        if let timerValue = timerAccessibilityValue {
            chipContent
                .accessibilityLabel(Text("More options"))
                .accessibilityValue(Text(timerValue))
        } else {
            chipContent
                .accessibilityLabel(Text("More options"))
        }
    }

    private var chipContent: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "ellipsis.circle.fill")
                .font(.title2)
            if timerAccessibilityValue != nil {
                Image(systemName: "moon.fill")
                    .font(.system(size: 8, weight: .bold))
                    .padding(3)
                    .background(model.coverTheme.chip, in: Circle())
                    .offset(x: 2, y: -2)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .foregroundStyle(model.resolvedThemeTint ?? .accentColor)
    }

    private var timerAccessibilityValue: String? {
        PlayerMoreMenuState.timerAccessibilityValue(
            showsReaderSleepTimer: showsReaderSleepTimer,
            mode: model.sleepTimerMode,
            remainingSeconds: model.sleepTimerRemainingSeconds
        )
    }
}
