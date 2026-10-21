// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS)
import SwiftUI

struct WatchInboxSettingsView: View {
    @Environment(PlayerModel.self) private var model
    @Environment(SettingsManager.self) private var settings
    @State private var relay = WatchInboxRelay.shared
    @State private var endpoint = ""
    @State private var key = ""
    @State private var saved = false
    @State private var saveError: String?

    var body: some View {
        Form {
            Section {
                TextField("Webhook URL", text: $endpoint)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Webhook Key", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save Inbox Setup", action: save)
                if saved { Label("Inbox setup saved", systemImage: "checkmark.circle.fill") }
                if let saveError { Text(saveError).foregroundStyle(.red) }
            } header: {
                Text("Inbox Webhook")
            } footer: {
                Text("Use the same webhook URL and key as MacroMark to send to the same inbox. The key is stored securely on this iPhone. Leave it blank to keep the key for the current URL.")
            }

            Section("Delivery") {
                LabeledContent("Setup", value: relay.isConfigured ? "Ready" : "Not configured")
                LabeledContent("Queued", value: relay.pendingCount.formatted())
                if let date = relay.lastAcceptedAt {
                    LabeledContent("Last accepted") { Text(date, format: .dateTime.month().day().hour().minute()) }
                }
                if let error = relay.lastError { Text(error).foregroundStyle(.secondary) }
                Button("Check Deliveries") { relay.retryPendingDeliveries() }
            }

            Section {
                Text("On your watch, tap Inbox to open dictation. Finish with double tap or Done to send, then return to listening. Thoughts can be captured without a book open.")
                Text("A haptic means the message is saved on your watch. It stays queued until the webhook accepts it; acceptance does not mean Audy has finished processing it.")
                Text("New layouts include Inbox. Saving setup adds it to an empty button slot in your current layout when one is available. You can also choose Inbox in the Watch button editor.")
            }
        }
        .navigationTitle("Watch Inbox")
        .task {
            endpoint = relay.configuredURL
            relay.start()
        }
    }

    private func save() {
        do {
            try relay.saveConfiguration(url: endpoint, key: key)
            addInboxButtonIfAvailable()
            key = ""
            saveError = nil
            saved = true
            model.syncToWatch()
        } catch {
            saved = false
            saveError = (error as? WatchInboxError)?.errorDescription ?? "Inbox setup could not be saved securely. Please try again."
        }
    }

    private func addInboxButtonIfAvailable() {
        var pages = [settings.watchPage1, settings.watchPage2, settings.watchPage3, settings.watchPage4, settings.watchPage5]
        guard !pages.joined().contains(.inbox) else { return }
        for page in pages.indices {
            if let slot = pages[page].firstIndex(of: .empty) {
                pages[page][slot] = .inbox
                settings.watchPage1 = pages[0]
                settings.watchPage2 = pages[1]
                settings.watchPage3 = pages[2]
                settings.watchPage4 = pages[3]
                settings.watchPage5 = pages[4]
                return
            }
        }
    }
}
#endif
