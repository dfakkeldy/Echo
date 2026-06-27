// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct ProTranscriptsSettingsView: View {
    @Environment(StoreManager.self) private var storeManager
    @State private var isRestoringPurchases = false
    @State private var isRetryingProducts = false
    @State private var showingPaywall = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    Text(
                        storeManager.hasUnlockedPro
                            ? String(localized: "Unlocked") : String(localized: "Locked")
                    )
                    .foregroundStyle(storeManager.hasUnlockedPro ? .green : .secondary)
                }

                if !storeManager.hasUnlockedPro {
                    Button("View Echo Pro Plans") {
                        showingPaywall = true
                    }

                    Button {
                        Task { await retryProducts() }
                    } label: {
                        if isRetryingProducts {
                            ProgressView()
                        } else {
                            Text("Retry Loading Purchase")
                        }
                    }
                    .disabled(isRetryingProducts || isRestoringPurchases)
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
                .disabled(isRestoringPurchases)
            } footer: {
                Text("Echo Pro unlocks transcript overlays plus unlimited study and narration tools.")
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
        .navigationTitle("Echo Pro")
        .task {
            if storeManager.products.isEmpty {
                await storeManager.requestProducts()
            }
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView(context: .settings)
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
