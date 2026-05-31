import SwiftUI

struct ReaderSettingsSheet: View {
    @Binding var settings: ReaderSettings
    @Environment(\.dismiss) private var dismiss

    private let colorSwatches: [(String, String)] = [
        ("#F5F0E8", "Sepia"),
        ("#FFF8E7", "Cream"),
        ("#FFFFFF", "White"),
        ("#F0F0F0", "Light Gray"),
        ("#2C2C2C", "Dark"),
        ("#000000", "Black"),
        ("#E8F5E9", "Soft Green"),
        ("#E3F2FD", "Soft Blue"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Font Size") {
                    Stepper("\(Int(settings.fontSize)) pt", value: $settings.fontSize, in: 12...28, step: 1)
                    Text("The quick brown fox jumps over the lazy dog.")
                        .font(.system(size: settings.fontSize))
                        .lineLimit(2)
                }

                Section("Line Spacing") {
                    VStack {
                        Slider(value: $settings.lineSpacing, in: 1.0...2.5, step: 0.1)
                        Text(String(format: "%.1f×", settings.lineSpacing))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section("Card Background") {
                    LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 4), spacing: 12) {
                        ForEach(colorSwatches, id: \.0) { (hex, name) in
                            Button {
                                settings.cardTintHex = hex
                            } label: {
                                VStack(spacing: 4) {
                                    Circle()
                                        .fill(Color(hex: hex))
                                        .frame(width: 44, height: 44)
                                        .overlay(
                                            settings.cardTintHex == hex
                                                ? Image(systemName: "checkmark")
                                                    .foregroundColor(hex == "#000000" || hex == "#2C2C2C" ? .white : .black)
                                                : nil
                                        )
                                        .overlay(
                                            Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                        )
                                    Text(name)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 8)
                }

                Section {
                    Button("Reset to Defaults", role: .destructive) {
                        settings.fontSize = 17.0
                        settings.lineSpacing = 1.4
                        settings.cardTintHex = "#F5F0E8"
                    }
                }
            }
            .navigationTitle("Reader Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: Double
        switch hex.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255
            g = Double((int >> 8) & 0xFF) / 255
            b = Double(int & 0xFF) / 255
        default:
            r = 1; g = 1; b = 1
        }
        self.init(red: r, green: g, blue: b)
    }
}
