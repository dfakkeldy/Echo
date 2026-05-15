import SwiftUI
import StoreKit

struct SettingsView: View {
    @Bindable var model: PlayerModel
    @Environment(SettingsManager.self) private var settings
    @Environment(StoreManager.self) private var storeManager
    @Environment(\.dismiss) private var dismiss
    @State private var isPurchasingPro = false
    @State private var isRestoringPurchases = false
    @State private var isRetryingProducts = false

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                Section {
                    NavigationLink("Appearance") {
                        Form {
                            Section {
                                Toggle("Dark Mode", isOn: $settings.isDarkMode)
                            }
                            Section {
                                Picker("Font", selection: $settings.appFont) {
                                    Text("Lexend (Default)").tag("Lexend")
                                    Text("OpenDyslexic").tag("OpenDyslexic")
                                    Text("System").tag(SettingsManager.systemFontName)
                                }
                            }
                        }
                        .navigationTitle("Appearance")
                    }
                }
                Section {
                    NavigationLink("Pro Transcripts") {
                        ProTranscriptsSettingsView(
                            isPurchasingPro: $isPurchasingPro,
                            isRestoringPurchases: $isRestoringPurchases,
                            isRetryingProducts: $isRetryingProducts
                        )
                    }
                }
                Section {
                    NavigationLink("Watch App") {
                        WatchAppSettingsView(model: model)
                    }
                }
                Section {
                    NavigationLink("Smart Rewind") {
                        SmartRewindSettingsView()
                    }
                }
                Section(footer: Text("When enabled, voice memos attached to bookmarks are played automatically when the audiobook reaches that timestamp.")) {
                    Toggle("Play Bookmarks Inline", isOn: $settings.playBookmarksInline)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .environment(\.font, settings.appFont == SettingsManager.systemFontName ? .body : .custom(settings.appFont, size: 17, relativeTo: .body))
        .preferredColorScheme(settings.isDarkMode ? .dark : .light)
    }
}

private struct ProTranscriptsSettingsView: View {
    @Environment(StoreManager.self) private var storeManager
    @Binding var isPurchasingPro: Bool
    @Binding var isRestoringPurchases: Bool
    @Binding var isRetryingProducts: Bool

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    Text(storeManager.hasUnlockedPro ? "Unlocked" : "Locked")
                        .foregroundStyle(storeManager.hasUnlockedPro ? .green : .secondary)
                }

                if let product = storeManager.proUnlockProduct, !storeManager.hasUnlockedPro {
                    Button {
                        Task { await purchasePro() }
                    } label: {
                        if isPurchasingPro {
                            ProgressView()
                        } else {
                            Text("Unlock for \(product.displayPrice)")
                        }
                    }
                    .disabled(isPurchasingPro || isRestoringPurchases)
                } else if !storeManager.hasUnlockedPro {
                    Button {
                        Task { await retryProducts() }
                    } label: {
                        if isRetryingProducts {
                            ProgressView()
                        } else {
                            Text("Retry Loading Purchase")
                        }
                    }
                    .disabled(isRetryingProducts || isPurchasingPro || isRestoringPurchases)
                }

                Button {
                    Task { await restorePurchases() }
                } label: {
                    if isRestoringPurchases {
                        ProgressView()
                    } else {
                        Text("Restore Purchases")
                    }
                }
                .disabled(isPurchasingPro || isRestoringPurchases)
            } footer: {
                Text("Unlock transcript overlays for audiobooks with transcript sidecars.")
            }

            if let lastStoreError = storeManager.lastStoreError {
                Section {
                    Text(lastStoreError)
                        .foregroundStyle(.red)
                } header: {
                    Text("StoreKit Error")
                }
            }
        }
        .navigationTitle("Pro Transcripts")
        .task {
            if storeManager.proUnlockProduct == nil {
                await storeManager.requestProducts()
            }
        }
    }

    private func purchasePro() async {
        isPurchasingPro = true
        defer { isPurchasingPro = false }
        do {
            try await storeManager.purchaseProUnlock()
        } catch {
            storeManager.recordStoreError(error)
        }
    }

    private func restorePurchases() async {
        isRestoringPurchases = true
        defer { isRestoringPurchases = false }
        await storeManager.restorePurchases()
    }

    private func retryProducts() async {
        isRetryingProducts = true
        defer { isRetryingProducts = false }
        await storeManager.requestProducts()
    }
}
