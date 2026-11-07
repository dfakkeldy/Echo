// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
#if os(iOS)
import PencilKit

// MARK: - DoodlePadView

/// A PencilKit canvas with color picker and clear button.
/// Drawings are auto-saved to the App Group container on disappear,
/// keyed by audiobookID so each book keeps its own set of doodles.
struct DoodlePadView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var canvasView = PKCanvasView()
    /// Index into `colors`; 0 is the ink that contrasts with the canvas.
    @State private var selectedIndex = 0
    @State private var hasDrawn = false
    let audiobookID: String

    /// The first swatch is "ink": white on the dark canvas, black on the light
    /// one, so the default pen is never invisible against its own page.
    private var colors: [Color] {
        [colorScheme == .dark ? .white : .black, .red, .blue, .green, .orange, .purple]
    }

    private static let colorNames: [LocalizedStringKey] = [
        "Ink", "Red", "Blue", "Green", "Orange", "Purple",
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Color palette + trash, in its own padded band above the canvas.
            HStack(spacing: 12) {
                ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
                    Circle()
                        .fill(color)
                        .frame(width: 28, height: 28)
                        .overlay(
                            Circle().stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                        )
                        .padding(3)
                        .overlay(
                            Circle()
                                .stroke(
                                    index == selectedIndex ? Color.accentColor : Color.clear,
                                    lineWidth: 2)
                        )
                        .contentShape(Circle())
                        .onTapGesture { select(index) }
                        .accessibilityElement()
                        .accessibilityLabel(Text(Self.colorNames[index]))
                        .accessibilityAddTraits(
                            index == selectedIndex ? [.isButton, .isSelected] : .isButton)
                }
                Spacer()
                Button {
                    canvasView.drawing = PKDrawing()
                    hasDrawn = false
                } label: {
                    Image(systemName: "trash")
                        .font(.title3)
                }
                .accessibilityLabel("Clear drawing")
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 16)

            // PencilKit canvas: an inset, rounded surface that belongs to the
            // sheet and runs to its bottom edge.
            PKCanvasRepresentable(canvasView: $canvasView) {
                hasDrawn = true
            }
            .onAppear {
                canvasView.backgroundColor = .clear
                canvasView.isOpaque = false
                canvasView.drawingPolicy = .anyInput
                applyTool()
                hasDrawn = !canvasView.drawing.bounds.isEmpty
            }
            .onDisappear {
                saveDrawing()
            }
            .onChange(of: colorScheme) { _, _ in applyTool() }
            .background(Color(uiColor: .secondarySystemBackground))
            .overlay {
                if !hasDrawn {
                    Text("Draw anything")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .clipShape(.rect(cornerRadius: 20, style: .continuous))
            .padding(.horizontal)
            .padding(.bottom, 8)
            .animation(.easeOut(duration: 0.2), value: hasDrawn)
        }
    }

    private func select(_ index: Int) {
        selectedIndex = index
        applyTool()
    }

    private func applyTool() {
        let color = colors[min(selectedIndex, colors.count - 1)]
        canvasView.tool = PKInkingTool(.pen, color: UIColor(color), width: 3)
    }

    // MARK: - Persistence

    private func saveDrawing() {
        guard !canvasView.drawing.bounds.isEmpty else { return }
        guard let dir = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.echo.audiobooks")?
            .appendingPathComponent("doodles/\(audiobookID)") else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(UUID().uuidString).png")
        if let data = canvasView.drawing.image(from: canvasView.drawing.bounds, scale: 1.0).pngData() {
            try? data.write(to: url)
        }
    }
}

// MARK: - PKCanvasRepresentable

/// Bridges a `PKCanvasView` into SwiftUI via `UIViewRepresentable`.
private struct PKCanvasRepresentable: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView
    /// Called on the first stroke so the "Draw anything" hint can fade out.
    var onDraw: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onDraw: onDraw)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.delegate = context.coordinator
        return canvasView
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        context.coordinator.onDraw = onDraw
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var onDraw: () -> Void

        init(onDraw: @escaping () -> Void) {
            self.onDraw = onDraw
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            onDraw()
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            if !canvasView.drawing.bounds.isEmpty { onDraw() }
        }
    }
}

#endif
