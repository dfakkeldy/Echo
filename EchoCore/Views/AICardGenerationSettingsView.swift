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
            // No "Generator" header over a "Generator" row.
            Section {
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

            // On-device only never uses the cloud provider, so its settings
            // stay out of the way. The stored config is left untouched.
            if preference != .onDevice {
                cloudSections
            }
        }
        .onAppear { loadStoredState() }
    }

    @ViewBuilder
    private var cloudSections: some View {
        Section {
            Picker("Provider", selection: $config.preset) {
                ForEach(AIProviderPreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .onChange(of: config.preset) { _, new in
                switchPreset(to: new)
            }

            // Label + trailing value, so model IDs and the endpoint are
            // never bare, unexplained rows.
            LabeledContent("Endpoint") {
                TextField("https://", text: $config.baseURL)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("API token") {
                SecureField("Required", text: $token)
                    .textContentType(.password)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Model") {
                TextField("Required", text: $config.primaryModel)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Fast model") {
                TextField("Optional", text: $lightModel)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
            }

            // Preset providers have fixed capabilities: show them as plain
            // values instead of dimmed toggles that read as neither on nor off.
            if config.preset == .custom {
                Toggle(
                    "Structured output",
                    isOn: $config.capabilities.supportsStructuredOutput
                )
                Toggle("Extended thinking", isOn: $config.capabilities.supportsThinking)
            } else {
                LabeledContent(
                    "Structured output",
                    value: config.capabilities.supportsStructuredOutput
                        ? String(localized: "Supported") : String(localized: "Not supported")
                )
                LabeledContent(
                    "Extended thinking",
                    value: config.capabilities.supportsThinking
                        ? String(localized: "Supported") : String(localized: "Not supported")
                )
            }
        } header: {
            Text("Cloud Provider")
        } footer: {
            Text("The fast model writes the short book brief.")
        }

        Section {
            Toggle(
                "I understand this book's text is sent to \(config.preset.displayName) using my token",
                isOn: $consented
            )

            Button(saved ? "Saved" : "Save") { save() }
                .disabled(!canSave)

            if store.token(for: config.preset) != nil {
                Button("Remove Token", role: .destructive) { removeToken() }
            }
        } footer: {
            if !canSave && !saved {
                Text(saveRequirement)
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
        } footer: {
            Text(
                "Generating cards sends this book's text to \(config.preset.displayName) over HTTPS, billed to your own account. Echo's other features (narration, alignment, playback) remain fully on-device."
            )
        }
    }

    private var canSave: Bool {
        !token.isEmpty && consented && !config.baseURL.isEmpty && !config.primaryModel.isEmpty
    }

    /// The one thing still missing before Save can run.
    private var saveRequirement: String {
        if config.baseURL.isEmpty { return String(localized: "Enter an endpoint to save.") }
        if token.isEmpty { return String(localized: "Enter an API token to save.") }
        if config.primaryModel.isEmpty { return String(localized: "Enter a model to save.") }
        return String(localized: "Accept the notice above to save.")
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
