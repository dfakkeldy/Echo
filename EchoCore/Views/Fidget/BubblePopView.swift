import SwiftUI

// MARK: - BubblePopView

/// A grid of circles drawn on a SwiftUI `Canvas`. Tap a bubble to pop it
/// with haptic feedback. Once all bubbles are popped they auto-regenerate
/// after a short delay.
struct BubblePopView: View {
    @State private var bubbles: [Bubble] = []
    @State private var popCount = 0
    @State private var isRegenerating = false

    let columns = 6
    let rows = 10

    struct Bubble: Identifiable {
        let id = UUID()
        let x: Int
        let y: Int
        var isPopped = false
    }

    var body: some View {
        VStack(spacing: 6) {
            Text("Popped: \(popCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())

            GeometryReader { geo in
                let cellW = geo.size.width / CGFloat(columns)
                let cellH = geo.size.height / CGFloat(rows)

                Canvas { context, _ in
                    for bubble in bubbles where !bubble.isPopped {
                        let rect = CGRect(
                            x: CGFloat(bubble.x) * cellW + 3,
                            y: CGFloat(bubble.y) * cellH + 3,
                            width: cellW - 6,
                            height: cellH - 6
                        )
                        context.fill(Path(ellipseIn: rect), with: .color(.blue.opacity(0.35)))
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            popBubble(at: value.location, cellW: cellW, cellH: cellH)
                        }
                )
            }
        }
        .padding()
        .onAppear {
            populateBubbles()
        }
    }

    // MARK: - Helpers

    private func populateBubbles() {
        bubbles = (0..<rows).flatMap { y in
            (0..<columns).map { x in
                Bubble(x: x, y: y)
            }
        }
        popCount = 0
    }

    private func popBubble(at location: CGPoint, cellW: CGFloat, cellH: CGFloat) {
        let col = Int(location.x / cellW)
        let row = Int(location.y / cellH)
        guard row >= 0, row < rows, col >= 0, col < columns else { return }

        let index = row * columns + col
        guard index < bubbles.count, !bubbles[index].isPopped else { return }

        bubbles[index].isPopped = true
        popCount += 1

#if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
#endif

        // Auto-regenerate once every bubble is popped
        let remaining = bubbles.filter { !$0.isPopped }.count
        if remaining == 0 && !isRegenerating {
            isRegenerating = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                withAnimation(.easeOut(duration: 0.3)) {
                    populateBubbles()
                }
                isRegenerating = false
            }
        }
    }
}
