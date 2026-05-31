import SwiftUI

/// Compact color picker for a single card. Reuses the same swatches as ReaderSettingsSheet.
struct CardColorPickerSheet: View {
    let blockID: String
    let onSelect: (String, String?) -> Void  // (blockID, colorHex or nil for reset)
    @Environment(\.dismiss) private var dismiss

    private let colorSwatches: [(String, String)] = [
        // Bright Highlighters
        ("#FFF59D", "Yellow"),
        ("#C5E1A5", "Green"),
        ("#81D4FA", "Blue"),
        ("#F48FB1", "Pink"),
        ("#CE93D8", "Purple"),
        ("#FFCC80", "Orange"),
        
        // Subtle / Dark Mode
        ("#F5F0E8", "Sepia"),
        ("#F0F0F0", "Light Gray"),
        ("#2C2C2E", "Dark Gray"),
        ("#1C1C1E", "Deep Black")
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Choose a background color for this card.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 4), spacing: 16) {
                    ForEach(colorSwatches, id: \.0) { (hex, name) in
                        Button {
                            onSelect(blockID, hex)
                            dismiss()
                        } label: {
                            VStack(spacing: 4) {
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 48, height: 48)
                                    .overlay(
                                        Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                    )
                                Text(name)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)

                Button("Reset to Default", role: .destructive) {
                    onSelect(blockID, nil)
                    dismiss()
                }
                .padding(.top, 8)
            }
            .padding(.vertical)
            .navigationTitle("Card Color")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
