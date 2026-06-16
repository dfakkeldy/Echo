// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// A horizontal auto-scrolling marquee text component that handles text that
/// exceeds screen width by scrolling it smoothly after a 2-second delay.
struct MarqueeText: View {
    let text: String
    var fontStyle: Font.TextStyle = .body
    var fontWeight: Font.Weight = .regular
    var appFont: String = SettingsManager.systemFontName
    var foregroundStyle: Color = .primary

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var scrollTask: Task<Void, Never>? = nil

    var body: some View {
        GeometryReader { geo in
            let cWidth = geo.size.width
            // Only scroll — and only apply the scroll offset — when the text genuinely
            // overflows the container. Otherwise center it and pin offset to 0 so a short
            // title can never be shifted off-screen by a stale width measurement.
            let fits = textWidth <= cWidth

            Text(text)
                .customFont(fontStyle, weight: fontWeight, appFont: appFont)
                .foregroundStyle(foregroundStyle)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .background(
                    GeometryReader { textGeo in
                        Color.clear.onAppear {
                            textWidth = textGeo.size.width
                        }
                        .onChange(of: text) { _, _ in
                            textWidth = textGeo.size.width
                        }
                    }
                )
                .offset(x: fits ? 0 : offset)
                // Honor the container's center alignment when not scrolling.
                .frame(maxWidth: .infinity, alignment: fits ? .center : .leading)
                .onAppear {
                    containerWidth = cWidth
                    startScrolling(distance: textWidth - cWidth)
                }
                .onChange(of: text) { _, _ in
                    containerWidth = cWidth
                    startScrolling(distance: textWidth - cWidth)
                }
                .onChange(of: cWidth) { _, newWidth in
                    containerWidth = newWidth
                    startScrolling(distance: textWidth - newWidth)
                }
                .onChange(of: textWidth) { _, newTextWidth in
                    // Re-evaluate once the real text width is known so a title that
                    // shrank doesn't retain a stale scroll offset.
                    startScrolling(distance: newTextWidth - cWidth)
                }
        }
        .frame(height: fontStyle == .title3 ? 32 : 24)
        .clipped()
    }

    private func startScrolling(distance: CGFloat) {
        scrollTask?.cancel()
        offset = 0
        guard distance > 0 else { return }

        scrollTask = Task {
            while !Task.isCancelled {
                // 1. Initial 2-second delay
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }

                // 2. Scroll smoothly to the end (30 points per second speed)
                let duration = Double(distance) / 30.0
                withAnimation(.linear(duration: duration)) {
                    offset = -distance
                }

                // Wait for the duration of the scroll
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }

                // 3. Pause at the end for 2 seconds
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }

                // 4. Reset to the start instantly
                offset = 0
            }
        }
    }
}
