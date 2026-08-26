// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import os.log

#if os(iOS)
    struct AppIconSelectionView: View {
        let icons: [(name: String, id: String?)] = [
            ("Default (Original)", nil),
            ("Circuit Brain", "AppIcon-CircuitBrain"),
            ("Complex Waves", "AppIcon-ComplexWaves"),
            ("Gold & Silver", "AppIcon-GoldSilver"),
            ("Silver & Gold", "AppIcon-SilverGold"),
            ("White Bolder", "AppIcon-WhiteBolder"),
        ]

        @State private var currentIcon = UIApplication.shared.alternateIconName

        var body: some View {
            Form {
                ForEach(icons, id: \.name) { icon in
                    Button {
                        setAppIcon(to: icon.id)
                    } label: {
                        HStack {
                            // We use the image from the bundle if we want to preview it,
                            // but since they are app icons, we can't easily load them into an Image directly.
                            // So we just show the name.
                            Text(icon.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if currentIcon == icon.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            }
            .navigationTitle("App Icon")
            .navigationBarTitleDisplayMode(.inline)
        }

        private func setAppIcon(to iconName: String?) {
            guard UIApplication.shared.supportsAlternateIcons else { return }
            UIApplication.shared.setAlternateIconName(iconName) { error in
                if let error = error {
                    Logger(category: "Settings").error(
                        "Failed to change app icon: \(error.localizedDescription)")
                } else {
                    Task { @MainActor in
                        self.currentIcon = iconName
                    }
                }
            }
        }
    }
#endif
