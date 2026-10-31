// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// The Play/Pause hero disc. It used to sit inside a book-progress ring with
/// a hidden double-tap chapter/book toggle; the ring duplicated the book track
/// under the scrubber (ticks + "Chapter 1 of 20 · 1% of book") and was
/// invisible early in a book, so the scrubber area now owns progress alone.
/// The 92pt footprint is kept so the transport row's layout does not shift.
struct PlayPauseHeroButton: View {
    let isPlaying: Bool
    let action: () -> Void
    var longPressAction: WatchAction = .empty
    let model: PlayerModel

    var body: some View {
        TransportButton(
            tapAction: action,
            longPressAction: longPressAction,
            model: model
        ) {
            ZStack {
                Circle()
                    .fill(model.resolvedThemeTint ?? .accentColor)
                    .frame(width: 78, height: 78)

                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(model.coverTheme.onAccent)
            }
        }
        .frame(width: 92, height: 92)
        .contentShape(Circle())
    }
}
