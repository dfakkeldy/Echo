// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct ReaderSettingsSheet: View {
    @Binding var settings: ReaderSettings
    #if os(iOS)
        @Environment(PlayerModel.self) private var model
    #endif
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingReset = false

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
        // Presented from the reader's book chrome, so it continues the cover's
        // tonal room like the other book sheets. (The cover scaffold and
        // PlayerModel are iOS-only; this file also builds for macOS.)
        #if os(iOS)
            CoverThemedSheet(theme: model.coverTheme) { form }
        #else
            NavigationStack { form }
        #endif
    }

    private var form: some View {
        Form {
            Section("Font Size") {
                Stepper(
                    "\(Int(settings.fontSize)) pt", value: $settings.fontSize, in: 12...28, step: 1)
                    .tonalCardRow()
                // The sample is drawn the way the reader draws a card — the
                // chosen tint washed over the page with a tinted edge, at the
                // chosen size and line spacing — so every change shows here.
                Text("The quick brown fox jumps over the lazy dog.")
                    .font(.system(size: settings.fontSize))
                    .lineSpacing(settings.fontSize * max(0, settings.lineSpacing - 1))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background { pagePreviewBackground.clipShape(.rect(cornerRadius: 10)) }
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(hex: settings.cardTintHex).opacity(0.5), lineWidth: 1)
                    )
                    .padding(.vertical, 4)
                    .tonalCardRow()
            }

            Section("Line Spacing") {
                HStack(spacing: 12) {
                    Slider(value: $settings.lineSpacing, in: 1.0...2.5, step: 0.1)
                    Text(verbatim: lineSpacingMultiplierText)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 36, alignment: .trailing)
                }
                .tonalCardRow()
            }

            Section("Page Tint") {
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
                                                .foregroundStyle(
                                                    swatch.usesLightCheckmark ? .white : .black)
                                            : nil
                                    )
                                    .overlay(
                                        // A light ring keeps dark swatches visible
                                        // against a dark sheet.
                                        Circle().stroke(
                                            swatch.usesLightCheckmark
                                                ? Color.white.opacity(0.7)
                                                : Color.secondary.opacity(0.3),
                                            lineWidth: swatch.usesLightCheckmark ? 1.5 : 1
                                        )
                                    )
                                Text(swatch.name)
                                    .font(.caption2)
                                    .foregroundStyle(.primary.opacity(0.75))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 8)
                .tonalCardRow()
            }

            Section {
                // A plain row in its own card: resetting only undoes three
                // reading preferences, so it is not styled as destructive.
                // It still asks first, since it overwrites the user's choices.
                Button("Reset to Defaults") { confirmingReset = true }
                    .frame(maxWidth: .infinity)
                    .tonalCardRow()
                    .confirmationDialog(
                        "Reset reader settings?",
                        isPresented: $confirmingReset,
                        titleVisibility: .visible
                    ) {
                        Button("Reset to Defaults") {
                            settings.fontSize = 17.0
                            settings.lineSpacing = 1.4
                            settings.cardTintHex = "#F5F0E8"
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Font size, line spacing and page tint go back to 17 pt, 1.4× and Sepia.")
                    }
            }
        }
        .navigationTitle("Reader Settings")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("Done") { dismiss() }
            }
        }
    }

    /// The reader page: the system page colour with the tint washed over it
    /// at the same strength `ReaderTab` uses.
    private var pagePreviewBackground: some View {
        ZStack {
            #if canImport(UIKit)
                Color(uiColor: .systemBackground)
            #else
                Color(nsColor: .textBackgroundColor)
            #endif
            Color(hex: settings.cardTintHex).opacity(0.08)
        }
    }

    private var lineSpacingMultiplierText: String {
        settings.lineSpacing.formatted(.number.precision(.fractionLength(1))) + "×"
    }
}

extension View {
    /// Rows on the cover-wash sheet use the tonal card fill, not system grey.
    /// (The wash and its card fill are iOS-only; macOS keeps the system card.)
    @ViewBuilder
    fileprivate func tonalCardRow() -> some View {
        #if os(iOS)
            listRowBackground(CoverSheetRowBackground())
        #else
            self
        #endif
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
        let r: Double
        let g: Double
        let b: Double
        switch hex.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255
            g = Double((int >> 8) & 0xFF) / 255
            b = Double(int & 0xFF) / 255
        default:
            r = 1
            g = 1
            b = 1
        }
        self.init(red: r, green: g, blue: b)
    }
}
