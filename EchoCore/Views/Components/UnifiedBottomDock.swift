// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct UnifiedBottomDock: View {
    @Environment(PlayerModel.self) private var model
    static let bottomEdgePadding: CGFloat = 4

    var onCreateBookmark: (BookmarkDraft) -> Void
    var onShowPlaybackOptions: () -> Void
    /// Player-More menu closures (WS-C), forwarded to BottomToolbarView.
    var onShowChapters: () -> Void
    var onShowBookmarks: () -> Void
    var onShowSettings: () -> Void
    // onShowFidget removed — Fidget now lives in the More menu (UnifiedTopHeader).

    /// Platform-agnostic separator color.
    @MainActor private var separatorColor: Color {
        #if canImport(UIKit)
            Color(uiColor: .separator)
        #elseif canImport(AppKit)
            Color(nsColor: .separatorColor)
        #else
            Color.primary.opacity(0.15)
        #endif
    }

    private var showsControls: Bool {
        model.selectedTab == .nowPlaying || (model.folderURL != nil && !model.tracks.isEmpty)
    }

    /// The stacked rows (controls/mini-player → divider → utility toolbar),
    /// extracted from `body` so the heavily-modified outer capsule chain and
    /// this inner stack type-check as separate expressions. Threading the WS-C
    /// More-menu closures through `BottomToolbarView` pushed the combined
    /// single-expression `body` past the Swift type-checker's time budget.
    @ViewBuilder private var stackedContent: some View {
        // A clean VStack of: controls (or mini-player) → divider → utility toolbar.
        // The capsule gets uniform `.padding(.vertical, 16)` (below) so each row
        // takes its natural, uncompressed height.
        VStack(spacing: 0) {
            // Upper layer: Large Controls (Now Playing) or Mini-player (other tabs)
            if model.selectedTab == .nowPlaying {
                TransportControlsView()
                    .padding(.horizontal, 16)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.95).combined(with: .opacity),
                            removal: .scale(scale: 0.95).combined(with: .opacity)
                        ))
            } else if model.folderURL != nil && !model.tracks.isEmpty {
                PlayerControlBar()
                    .padding(.horizontal, 16)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.95).combined(with: .opacity),
                            removal: .scale(scale: 0.95).combined(with: .opacity)
                        ))
            }

            // Divider separating controls from utility bar
            if showsControls {
                Divider()
                    .background(separatorColor.opacity(0.25))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            }

            // Lower layer: Static 5-Button Utility Bar
            BottomToolbarView(
                onCreateBookmark: onCreateBookmark,
                onShowChapters: onShowChapters,
                onShowBookmarks: onShowBookmarks,
                onShowSettings: onShowSettings,
                onShowPlaybackOptions: onShowPlaybackOptions,
                canCreateReaderCapture: model.readerCaptureAnchorBlockID != nil,
                isReaderVoiceMemoRecording: model.isReaderVoiceMemoRecording,
                onAddReaderNote: model.readerAddNoteAction,
                onToggleReaderMemo: model.readerToggleVoiceMemoAction
            )
            .padding(.horizontal, 16)
        }
    }

    var body: some View {
        stackedContent
            // Uniform vertical breathing room so the circular play-button progress
            // ring is never clipped by the capsule's rounded corners. Trimmed from
            // 16 → 10 so the deck reads as a compact capsule rather than a tall slab.
            .padding(.vertical, 10)
            // Explicit width via `containerRelativeFrame`, NOT `.frame(maxWidth:
            // .infinity)` + `.padding(.horizontal, 16)`: the transport/toolbar rows
            // are greedy (Spacers, `maxWidth: .infinity`) and overflow a
            // padding-reduced proposal back to full bleed, which pushed the
            // capsule's rounded side edges off-screen. A fixed width can't overflow.
            .containerRelativeFrame(.horizontal) { width, _ in max(0, width - 32) }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
            // Tint the system material backdrop with dynamic artwork theme
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(model.artworkAccentColor ?? .accentColor)
                    .opacity(0.08)
            )
            .shadow(color: Color.black.opacity(0.25), radius: 15, x: 0, y: 5)
            .padding(.bottom, Self.bottomEdgePadding)
    }
}
