// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct ReaderDefaultsSettingsView: View {
    @Environment(SettingsManager.self) private var settings

    private let colorSwatches: [ReaderDefaultsColorSwatch] = [
        ReaderDefaultsColorSwatch(hex: "#F5F0E8", name: "Sepia"),
        ReaderDefaultsColorSwatch(hex: "#FFF8E7", name: "Cream"),
        ReaderDefaultsColorSwatch(hex: "#FFFFFF", name: "White"),
        ReaderDefaultsColorSwatch(hex: "#F0F0F0", name: "Light Gray"),
        ReaderDefaultsColorSwatch(hex: "#2C2C2C", name: "Dark"),
        ReaderDefaultsColorSwatch(hex: "#000000", name: "Black"),
        ReaderDefaultsColorSwatch(hex: "#E8F5E9", name: "Soft Green"),
        ReaderDefaultsColorSwatch(hex: "#E3F2FD", name: "Soft Blue"),
    ]

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Font Size") {
                Stepper(
                    "\(Int(settings.readerFontSize)) pt",
                    value: $settings.readerFontSize,
                    in: 12...28,
                    step: 1
                )
                Text("The quick brown fox jumps over the lazy dog.")
                    .font(.system(size: settings.readerFontSize))
                    .lineLimit(2)
            }

            Section("Line Spacing") {
                VStack(alignment: .leading) {
                    Slider(
                        value: $settings.readerLineSpacing,
                        in: 1.0...2.5,
                        step: 0.1
                    )
                    Text(verbatim: lineSpacingMultiplierText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Card Background") {
                LazyVGrid(
                    columns: Array(repeating: .init(.flexible()), count: 4),
                    spacing: 12
                ) {
                    ForEach(colorSwatches) { swatch in
                        Button {
                            settings.readerCardTint = swatch.hex
                        } label: {
                            VStack(spacing: 4) {
                                Circle()
                                    .fill(Color(hex: swatch.hex))
                                    .frame(width: 44, height: 44)
                                    .overlay {
                                        if settings.readerCardTint == swatch.hex {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(
                                                    swatch.usesLightCheckmark ? .white : .black
                                                )
                                        }
                                    }
                                    .overlay {
                                        Circle().stroke(.secondary.opacity(0.3), lineWidth: 1)
                                    }
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
                    settings.readerFontSize = SettingsManager.Defaults.readerFontSize
                    settings.readerLineSpacing = SettingsManager.Defaults.readerLineSpacing
                    settings.readerCardTint = SettingsManager.Defaults.readerCardTint
                }
            }
        }
        .navigationTitle("Reader Defaults")
    }

    private var lineSpacingMultiplierText: String {
        settings.readerLineSpacing.formatted(.number.precision(.fractionLength(1))) + "×"
    }
}

private struct ReaderDefaultsColorSwatch: Identifiable {
    let hex: String
    let name: LocalizedStringResource

    var id: String { hex }

    var usesLightCheckmark: Bool {
        hex == "#000000" || hex == "#2C2C2C"
    }
}
