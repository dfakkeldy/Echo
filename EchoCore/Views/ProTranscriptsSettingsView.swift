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
            // What Pro gives comes first, then one clear action.
            Section {
                ForEach(Self.benefits, id: \.symbol) { benefit in
                    Label(benefit.title, systemImage: benefit.symbol)
                }
            } header: {
                Text("Echo Pro includes")
            }

            // While locked, the Unlock button already states the status;
            // a status line appears only once Pro is unlocked.
            if storeManager.hasUnlockedPro {
                Section {
                    LabeledContent("Status") {
                        Text(String(localized: "Unlocked"))
                            .foregroundStyle(.green)
                    }
                }
            }

            if !storeManager.hasUnlockedPro {
                Section {
                    if let product = storeManager.proUnlockProduct {
                        Button {
                            Task { await purchasePro() }
                        } label: {
                            Group {
                                if isPurchasingPro {
                                    ProgressView()
                                } else {
                                    Text(String(localized: "Unlock for \(product.displayPrice)"))
                                        .fontWeight(.semibold)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(isPurchasingPro || isRestoringPurchases)
                    } else {
                        Button {
                            Task { await retryProducts() }
                        } label: {
                            Group {
                                if isRetryingProducts {
                                    ProgressView()
                                } else {
                                    Text("Retry Loading Purchase")
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(isRetryingProducts || isPurchasingPro || isRestoringPurchases)
                    }
                } footer: {
                    // Centred on the button's axis, not left-aligned under it.
                    Text("One-time purchase. No subscription.")
                        .settingsFooterStyle()
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            // Restore is a quiet secondary link, not a second primary action.
            Section {
                Button {
                    Task { await restorePurchases() }
                } label: {
                    if isRestoringPurchases {
                        ProgressView()
                    } else {
                        // Body size: a quiet link, but still easy to read and hit.
                        Text("Restore Purchases")
                    }
                }
                .buttonStyle(.borderless)
                .frame(maxWidth: .infinity)
                .disabled(isPurchasingPro || isRestoringPurchases)
                .listRowBackground(Color.clear)
            }

            if let notice = storeManager.lastStoreNotice {
                Section {
                    Text(notice)
                        .foregroundStyle(.secondary)
                }
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
        // Matches the "Echo Pro" row that opens this page.
        .navigationTitle("Echo Pro")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if storeManager.proUnlockProduct == nil {
                await storeManager.requestProducts()
            }
        }
    }

    private struct Benefit {
        let title: LocalizedStringKey
        let symbol: String
    }

    private static let benefits: [Benefit] = [
        Benefit(title: "Transcript overlays", symbol: "text.bubble"),
        Benefit(title: "Unlimited flashcards", symbol: "rectangle.stack"),
        Benefit(title: "Study export", symbol: "square.and.arrow.up"),
        Benefit(title: "Listening and study insights", symbol: "chart.bar"),
        Benefit(title: "Apple Watch review", symbol: "applewatch"),
        Benefit(title: "Audiobookshelf offline sync", symbol: "arrow.triangle.2.circlepath"),
    ]

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
