// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct FontSelectionView: View {
    @Environment(SettingsManager.self) private var settings

    var body: some View {
        Form {
            Button {
                settings.appFont = "Lexend"
            } label: {
                HStack {
                    Text("Lexend (Default)")
                        .foregroundStyle(.primary)
                    Spacer()
                    if settings.appFont == "Lexend" {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            Button {
                settings.appFont = "OpenDyslexic"
            } label: {
                HStack {
                    Text("OpenDyslexic")
                        .foregroundStyle(.primary)
                    Spacer()
                    if settings.appFont == "OpenDyslexic" {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            Button {
                settings.appFont = SettingsManager.systemFontName
            } label: {
                HStack {
                    Text("System")
                        .foregroundStyle(.primary)
                    Spacer()
                    if settings.appFont == SettingsManager.systemFontName {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
        .navigationTitle("Font")
        .navigationBarTitleDisplayMode(.inline)
    }
}
