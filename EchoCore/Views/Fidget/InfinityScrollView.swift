import SwiftUI

// MARK: - InfinityScrollView

/// An endless horizontal scrolling pattern rendered with SpriteKit.
/// Rows of coloured shapes scroll from right to left and recycle
/// when they exit the frame, creating a soothing infinite loop.
#if os(iOS)
import SpriteKit

struct InfinityScrollView: View {
    var body: some View {
        SpriteView(scene: scrollingScene(), options: [.allowsTransparency])
            .ignoresSafeArea()
    }

    private func scrollingScene() -> SKScene {
        let scene = InfinityScrollScene()
        scene.size = CGSize(width: 400, height: 800)
        scene.scaleMode = .fill
        scene.backgroundColor = .clear
        return scene
    }
}

// MARK: - InfinityScrollScene

private class InfinityScrollScene: SKScene {
    private var contentWidth: CGFloat = 0
    private let scrollSpeed: CGFloat = 60 // points per second

    override func didMove(to view: SKView) {
        buildRows()
    }

    // MARK: - Row builder

    private func buildRows() {
        guard let view else { return }
        let w = view.bounds.width
        let h = view.bounds.height
        contentWidth = w

        // Clear any previous nodes
        removeAllChildren()

        let rowCount = 8
        let rowHeight = h / CGFloat(rowCount)
        let shapesPerRow = 12
        let spacing = (w * 2.5) / CGFloat(shapesPerRow) // extra room so repeat is seamless

        let shapeTypes: [(CGSize) -> SKShapeNode] = [
            { SKShapeNode(circleOfRadius: min($0.width, $0.height) / 2) },
            { SKShapeNode(rectOf: $0, cornerRadius: 4) },
            { SKShapeNode(rectOf: $0) },
        ]

        let colors: [UIColor] = [
            .systemBlue, .systemGreen, .systemOrange,
            .systemPink, .systemPurple, .systemTeal,
        ]

        for row in 0..<rowCount {
            let yCenter = CGFloat(row) * rowHeight + rowHeight / 2
            let shapeIndex = row % shapeTypes.count
            let color = colors[row % colors.count].withAlphaComponent(0.25)

            for i in 0..<shapesPerRow * 2 { // double for seamless wrap
                let size = CGSize(
                    width: CGFloat.random(in: 8...20),
                    height: CGFloat.random(in: 8...20)
                )
                let node = shapeTypes[shapeIndex](size)
                node.fillColor = color
                node.strokeColor = .clear
                node.position = CGPoint(
                    x: CGFloat(i) * spacing,
                    y: yCenter + CGFloat.random(in: -rowHeight * 0.3...rowHeight * 0.3)
                )
                node.setScale(CGFloat.random(in: 0.6...1.4))
                addChild(node)
            }
        }
    }

    // MARK: - Update loop

    override func update(_ currentTime: TimeInterval) {
        let dt = 1 / 60 // approximate; SceneKit handles delta internally
        let dx = scrollSpeed * CGFloat(dt)

        for node in children {
            node.position.x -= dx
            // Recycle when offscreen-left
            if node.position.x < -contentWidth {
                node.position.x += contentWidth * 3
            }
        }
    }
}

#else
// Stub for platforms without SpriteKit (watchOS etc.)
struct InfinityScrollView: View {
    var body: some View {
        Text("Endless scroll — coming soon")
            .font(.title3)
            .foregroundStyle(.secondary)
    }
}
#endif
