// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Cross-platform settings pane for AI card generation: provider preset dropdown,
/// per-provider endpoint/token/model fields, named consent, and Test Connection.
struct AICardGenerationSettingsView: View {
    @State private var config: AIProviderConfig = .defaults(for: .anthropic)
    @State private var token = ""
    @State private var lightModel = ""
    @State private var consented = false
    @State private var preference: StudyDeckGeneratorPreference = .auto
    @State private var saved = false
    @State private var isTesting = false
    @State private var testResult: String?

    private let store = AIProviderSettingsStore()

    var body: some View {
        Form {
            Section("Generator") {
                Picker("Generator", selection: $preference) {
                    Text("Automatic").tag(StudyDeckGeneratorPreference.auto)
                    Text("On-device only").tag(StudyDeckGeneratorPreference.onDevice)
                    Text("Cloud only").tag(StudyDeckGeneratorPreference.cloud)
                }
                .onChange(of: preference) { _, new in
                    store.generatorPreference = new
                }
                Text(StudyDeckFMAvailability.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Cloud Provider") {
                Picker("Provider", selection: $config.preset) {
                    ForEach(AIProviderPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .onChange(of: config.preset) { _, new in
                    switchPreset(to: new)
                }

                TextField("Base URL", text: $config.baseURL)
                    .autocorrectionDisabled()
                SecureField("API token", text: $token)
                    .textContentType(.password)
                TextField("Model", text: $config.primaryModel)
                    .autocorrectionDisabled()
                TextField("Light model (book brief, optional)", text: $lightModel)
                    .autocorrectionDisabled()

                Toggle(
                    "Structured output",
                    isOn: $config.capabilities.supportsStructuredOutput
                )
                .disabled(config.preset != .custom)
                Toggle("Extended thinking", isOn: $config.capabilities.supportsThinking)
                    .disabled(config.preset != .custom)
            }

            Section {
                Toggle(
                    "I understand this book's text is sent to \(config.preset.displayName) using my token",
                    isOn: $consented
                )

                Button(saved ? "Saved" : "Save") { save() }
                    .disabled(
                        token.isEmpty || !consented
                            || config.baseURL.isEmpty || config.primaryModel.isEmpty
                    )

                if store.token(for: config.preset) != nil {
                    Button("Remove Token", role: .destructive) { removeToken() }
                }
            }

            Section {
                Button(isTesting ? "Testing..." : "Test Connection") { runConnectionTest() }
                    .disabled(isTesting || token.isEmpty || config.baseURL.isEmpty)
                if let testResult {
                    Text(testResult)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Text(
                    "Generating cards sends this book's text to \(config.preset.displayName) over HTTPS, billed to your own account. Echo's other features (narration, alignment, playback) remain fully on-device."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .onAppear { loadStoredState() }
    }

    private func loadStoredState() {
        preference = store.generatorPreference
        if let stored = store.config {
            config = stored
            consented = stored.consented
        } else {
            config = .defaults(for: .anthropic)
            consented = false
        }
        lightModel = config.lightModel ?? ""
        token = store.token(for: config.preset) ?? ""
    }

    private func switchPreset(to preset: AIProviderPreset) {
        if let stored = store.config, stored.preset == preset {
            config = stored
            consented = stored.consented
        } else {
            config = .defaults(for: preset)
            consented = false
        }
        lightModel = config.lightModel ?? ""
        token = store.token(for: preset) ?? ""
        testResult = nil
        saved = false
    }

    private func save() {
        guard consented else { return }
        var toSave = config
        let trimmedLight = lightModel.trimmingCharacters(in: .whitespacesAndNewlines)
        toSave.lightModel = trimmedLight.isEmpty ? nil : trimmedLight
        toSave.consented = true
        store.config = toSave
        store.setToken(token, for: toSave.preset)
        config = toSave
        saved = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            saved = false
        }
    }

    private func removeToken() {
        store.setToken(nil, for: config.preset)
        token = ""
        consented = false
        if var stored = store.config, stored.preset == config.preset {
            stored.consented = false
            store.config = stored
        }
    }

    private func runConnectionTest() {
        var draft = config
        let trimmedLight = lightModel.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.lightModel = trimmedLight.isEmpty ? nil : trimmedLight
        guard let clients = AnthropicMessagesClient.clients(config: draft, token: token) else {
            testResult = "Invalid base URL - enter a full https:// endpoint."
            return
        }

        isTesting = true
        testResult = nil
        Task { @MainActor in
            let outcome = await AIProviderConnectionTester(client: clients.primary).test()
            testResult = outcome.message
            isTesting = false
        }
    }
}
