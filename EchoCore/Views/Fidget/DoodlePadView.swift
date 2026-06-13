import SwiftUI
#if os(iOS)
import PencilKit

// MARK: - DoodlePadView

/// A PencilKit canvas with color picker and clear button.
/// Drawings are auto-saved to the App Group container on disappear,
/// keyed by audiobookID so each book keeps its own set of doodles.
struct DoodlePadView: View {
    @State private var canvasView = PKCanvasView()
    @State private var selectedColor: Color = .black
    let audiobookID: String

    let colors: [Color] = [.black, .red, .blue, .green, .orange, .purple]

    var body: some View {
        VStack(spacing: 0) {
            // Color palette + trash
            HStack(spacing: 12) {
                ForEach(colors, id: \.self) { color in
                    Circle()
                        .fill(color)
                        .frame(width: 28, height: 28)
                        .overlay(
                            Circle()
                                .stroke(color == selectedColor ? Color.primary : Color.clear,
                                        lineWidth: 2)
                        )
                        .onTapGesture {
                            selectedColor = color
                            canvasView.tool = PKInkingTool(.pen, color: UIColor(color), width: 3)
                        }
                }
                Spacer()
                Button {
                    canvasView.drawing = PKDrawing()
                } label: {
                    Image(systemName: "trash")
                        .font(.title3)
                }
                .accessibilityLabel("Clear drawing")
            }
            .padding(.horizontal)
            .padding(.top, 8)

            // PencilKit canvas
            PKCanvasRepresentable(canvasView: $canvasView)
                .onAppear {
                    canvasView.tool = PKInkingTool(.pen, color: UIColor(selectedColor), width: 3)
                    canvasView.drawingPolicy = .anyInput
                }
                .onDisappear {
                    saveDrawing()
                }
        }
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

    func makeUIView(context: Context) -> PKCanvasView {
        canvasView
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {}
}

#endif
