import SwiftUI

struct BookSettingsView: View {
    @Bindable var model: PlayerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Typography") {
                    Picker("Font Override", selection: Binding(
                        get: { model.bookFontOverride ?? "inherit" },
                        set: { newValue in
                            model.updateBookFontOverride(newValue == "inherit" ? nil : newValue)
                        }
                    )) {
                        Text("Inherit Global").tag("inherit")
                        Text("Lexend").tag("Lexend")
                        Text("OpenDyslexic").tag("OpenDyslexic")
                        Text("System").tag("System")
                    }
                }

                Section("Playback Overrides") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Play Bookmarks Inline")
                            .font(.subheadline)
                        Picker("Bookmarks Inline Mode", selection: Binding(
                            get: { model.bookPlayBookmarksInlineOverride ?? "inherit" },
                            set: { newValue in
                                model.updateBookPlayBookmarksInlineOverride(newValue == "inherit" ? nil : newValue)
                            }
                        )) {
                            Text("Inherit").tag("inherit")
                            Text("Always On").tag("alwaysOn")
                            Text("Always Off").tag("alwaysOff")
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Volume Boost")
                            .font(.subheadline)
                        Picker("Volume Boost Mode", selection: Binding(
                            get: { model.bookVolumeBoostOverride ?? "inherit" },
                            set: { newValue in
                                model.updateBookVolumeBoostOverride(newValue == "inherit" ? nil : newValue)
                            }
                        )) {
                            Text("Inherit").tag("inherit")
                            Text("Always On").tag("alwaysOn")
                            Text("Always Off").tag("alwaysOff")
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Book Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .environment(\.font, model.resolvedAppFont == SettingsManager.systemFontName ? .body : .custom(model.resolvedAppFont, size: 17, relativeTo: .body))
    }
}
