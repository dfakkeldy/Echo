// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// UserDefaults-backed AI card-generation preferences (model selection and provider).
/// The API key itself is stored in the Keychain via `APIKeyStore`.
enum AICardGenerationSettings {
    nonisolated private static let modelKey = "ai.cardgen.model"
    nonisolated private static let providerKey = "ai.cardgen.provider"

    static let models = ["claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5"]

    nonisolated static var selectedModel: String {
        get { UserDefaults.standard.string(forKey: modelKey) ?? "claude-opus-4-8" }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }

    nonisolated static var providerPreference: StudyDeckGeneratorPreference {
        get {
            StudyDeckGeneratorPreference(
                rawValue: UserDefaults.standard.string(forKey: providerKey) ?? "auto"
            ) ?? .auto
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: providerKey) }
    }
}

/// Cross-platform settings pane for AI card generation.
/// Allows the user to enter their Anthropic API key (BYO-key), choose a model,
/// and give one-time consent that book text is sent to Anthropic.
///
/// No iOS-only modifiers — compiles on macOS and echo-cli alike.
struct AICardGenerationSettingsView: View {
    @State private var key: String = ""
    @State private var model: String = AICardGenerationSettings.selectedModel
    @State private var provider: StudyDeckGeneratorPreference = AICardGenerationSettings
        .providerPreference
    @State private var consented = false
    @State private var saved = false

    // `APIKeyStore` is @MainActor; the View is also on @MainActor so this is fine.
    private let store = APIKeyStore()

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Generator", selection: $provider) {
                    Text("Automatic").tag(StudyDeckGeneratorPreference.auto)
                    Text("On-device only").tag(StudyDeckGeneratorPreference.onDevice)
                    Text("Cloud only").tag(StudyDeckGeneratorPreference.cloud)
                }
                .onChange(of: provider) { _, new in
                    AICardGenerationSettings.providerPreference = new
                }
                Text(StudyDeckFMAvailability.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("AI Card Generation") {
                SecureField("Anthropic API key", text: $key)
                    .textContentType(.password)

                Picker("Model", selection: $model) {
                    ForEach(AICardGenerationSettings.models, id: \.self) { m in
                        Text(m).tag(m)
                    }
                }

                Toggle(
                    "I understand the book's text is sent to Anthropic using my key",
                    isOn: $consented
                )

                Button(saved ? "Saved" : "Save") {
                    guard consented else { return }
                    store.anthropicKey = key
                    AICardGenerationSettings.selectedModel = model
                    saved = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.5))
                        saved = false
                    }
                }
                .disabled(key.isEmpty || !consented)

                if store.hasKey {
                    Button("Remove Key", role: .destructive) {
                        store.clear()
                        key = ""
                        consented = false
                    }
                }
            }

            Section {
                Text(
                    "Generating cards sends this book's text to Anthropic over HTTPS, billed to your own Anthropic account. Echo's other features (narration, alignment, playback) remain fully on-device."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            model = AICardGenerationSettings.selectedModel
            provider = AICardGenerationSettings.providerPreference
            // Pre-populate the field if a key is already stored so the user can
            // see there is one (masked by SecureField) without having to retype.
            if store.hasKey { key = store.anthropicKey ?? "" }
        }
    }
}
