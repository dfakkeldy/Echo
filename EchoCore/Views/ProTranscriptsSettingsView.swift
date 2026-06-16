// SPDX-License-Identifier: GPL-3.0-or-later
import StoreKit
import SwiftUI

struct ProTranscriptsSettingsView: View {
    @Environment(StoreManager.self) private var storeManager
    @State private var isPurchasingPro = false
    @State private var isRestoringPurchases = false
    @State private var isRetryingProducts = false

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

                if let product = storeManager.proUnlockProduct, !storeManager.hasUnlockedPro {
                    Button {
                        Task { await purchasePro() }
                    } label: {
                        if isPurchasingPro {
                            ProgressView()
                        } else {
                            Text(String(localized: "Unlock for \(product.displayPrice)"))
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
