// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// A single-line title that scrolls when it is wider than its container.
///
/// At rest the title always shows from its first letter, tail-truncated with an
/// ellipsis, so it never stops mid-glyph. After a 2-second pause an overflowing
/// title scrolls left as a ticker (the title, a gap, then the title again) and
/// stops exactly where it started, back on the first letter.
struct MarqueeText: View {
    let text: String
    var fontStyle: Font.TextStyle = .body
    var fontWeight: Font.Weight = .regular
    var appFont: String = SettingsManager.systemFontName
    var foregroundStyle: Color = .primary
    /// Where a title that fits sits in the container.
    var restingAlignment: Alignment = .center

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var isScrolling = false
    @State private var scrollTask: Task<Void, Never>? = nil

    /// Space between the title and its repeat while the ticker runs.
    private let gap: CGFloat = 40
    /// Scroll speed in points per second.
    private let speed: CGFloat = 30

    private var overflows: Bool {
        containerWidth > 0 && textWidth > containerWidth + 0.5
    }

    var body: some View {
        ZStack(alignment: .leading) {
            if isScrolling {
                HStack(spacing: gap) {
                    label
                    label.accessibilityHidden(true)
                }
                .fixedSize(horizontal: true, vertical: false)
                .offset(x: offset)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                label
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: overflows ? .leading : restingAlignment)
            }
        }
        .frame(height: fontStyle == .title3 ? 32 : 24)
        .clipped()
        .mask(edgeFade)
        // Measure the natural (unwrapped) title width off-screen.
        .background(alignment: .leading) {
            label
                .fixedSize(horizontal: true, vertical: false)
                .hidden()
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.width
                } action: {
                    textWidth = $0
                }
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            containerWidth = $0
        }
        .onChange(of: text) { _, _ in restart() }
        .onChange(of: textWidth) { _, _ in restart() }
        .onChange(of: containerWidth) { _, _ in restart() }
        .onAppear { restart() }
        .onDisappear { scrollTask?.cancel() }
    }

    private var label: some View {
        Text(text)
            .customFont(fontStyle, weight: fontWeight, appFont: appFont)
            .foregroundStyle(foregroundStyle)
            .lineLimit(1)
    }

    /// Soft trailing fade at rest, soft fades on both edges while scrolling, so
    /// glyphs dissolve at the edge instead of being sliced.
    @ViewBuilder
    private var edgeFade: some View {
        if isScrolling {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.06),
                    .init(color: .black, location: 0.94),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        } else {
            Rectangle()
        }
    }

    private func restart() {
        scrollTask?.cancel()
        offset = 0
        isScrolling = false
        guard overflows else { return }

        let distance = textWidth + gap
        let duration = Double(distance / speed)
        scrollTask = Task {
            while !Task.isCancelled {
                // Rest on the first letter, truncated, before each pass.
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }

                isScrolling = true
                // Let the ticker lay out at offset 0 before animating.
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                withAnimation(.linear(duration: duration)) {
                    offset = -distance
                }

                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }

                // The repeat now sits exactly where the title began: swap back
                // to the resting, truncated title with no visible jump.
                var reset = Transaction()
                reset.disablesAnimations = true
                withTransaction(reset) {
                    isScrolling = false
                    offset = 0
                }
            }
        }
    }
}
