// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct ReaderSettingsSheet: View {
    @Binding var settings: ReaderSettings
    @Environment(\.dismiss) private var dismiss

    private let colorSwatches: [ReaderColorSwatch] = [
        ReaderColorSwatch(hex: "#F5F0E8", name: "Sepia"),
        ReaderColorSwatch(hex: "#FFF8E7", name: "Cream"),
        ReaderColorSwatch(hex: "#FFFFFF", name: "White"),
        ReaderColorSwatch(hex: "#F0F0F0", name: "Light Gray"),
        ReaderColorSwatch(hex: "#2C2C2C", name: "Dark"),
        ReaderColorSwatch(hex: "#000000", name: "Black"),
        ReaderColorSwatch(hex: "#E8F5E9", name: "Soft Green"),
        ReaderColorSwatch(hex: "#E3F2FD", name: "Soft Blue"),
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
                        Text(verbatim: lineSpacingMultiplierText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Card Background") {
                    LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 4), spacing: 12) {
                        ForEach(colorSwatches) { swatch in
                            Button {
                                settings.cardTintHex = swatch.hex
                            } label: {
                                VStack(spacing: 4) {
                                    Circle()
                                        .fill(Color(hex: swatch.hex))
                                        .frame(width: 44, height: 44)
                                        .overlay(
                                            settings.cardTintHex == swatch.hex
                                                ? Image(systemName: "checkmark")
                                                    .foregroundStyle(swatch.usesLightCheckmark ? .white : .black)
                                                : nil
                                        )
                                        .overlay(
                                            Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                        )
                                    Text(swatch.name)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
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
                ToolbarItem(placement: .automatic) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var lineSpacingMultiplierText: String {
        settings.lineSpacing.formatted(.number.precision(.fractionLength(1))) + "×"
    }
}

private struct ReaderColorSwatch: Identifiable {
    let hex: String
    let name: LocalizedStringResource

    var id: String { hex }

    var usesLightCheckmark: Bool {
        hex == "#000000" || hex == "#2C2C2C"
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
