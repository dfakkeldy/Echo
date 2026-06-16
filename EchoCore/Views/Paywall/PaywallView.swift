// SPDX-License-Identifier: GPL-3.0-or-later
import StoreKit
import SwiftUI

struct PaywallView: View {
    let context: PaywallContext
    @Environment(StoreManager.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var trialEligible = false
    @State private var purchasing = false

    private func product(_ id: String) -> Product? {
        store.products.first { $0.id == id }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text("Echo Pro — turn listening into learning")
                        .font(.title2.bold())
                    Text(context.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    benefits

                    // Plan options — ALWAYS render product.displayPrice (sale-safe), never hardcode.
                    if let yearly = product(ProductIDs.yearly) {
                        planButton(yearly, badge: "Best value")
                    }
                    if let monthly = product(ProductIDs.monthly) {
                        planButton(monthly)
                    }
                    if let lifetime = product(ProductIDs.lifetime) {
                        planButton(lifetime, oneTime: true)
                    }
                    if FoundersWindow.isOpen, let founders = product(ProductIDs.founders) {
                        planButton(founders, oneTime: true, badge: "Founders — limited time")
                    }

                    if trialEligible {
                        Text("7 days free, then renews. Cancel anytime in Settings.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Button("Restore Purchases") {
                        Task {
                            await store.restorePurchases()
                            if store.isPro { dismiss() }
                        }
                    }
                    .font(.footnote)

                    HStack(spacing: 16) {
                        Link(
                            "Terms",
                            destination: URL(
                                string:
                                    "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"
                            )!)
                        Link(
                            "Privacy",
                            destination: URL(
                                string: "https://kinnokilabs.com/apps/echo/privacy")!)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Text("Open source — you can build it yourself.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if let err = store.lastStoreError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task {
                if store.products.isEmpty { await store.requestProducts() }
                trialEligible = await store.isEligibleForFreeTrial()
            }
        }
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 8) {
            benefitLabel("♾️", "Unlimited flashcards with SM-2 spaced repetition")
            benefitLabel("🗣️", "Unlimited on-device AI narration (coming in 1.0)")
            benefitLabel("📊", "Insights — listening & study streaks")
            benefitLabel("📤", "Study export — Markdown, Anki, JSON")
            benefitLabel("🔗", "AudiobookShelf offline & sync")
            benefitLabel("🔒", "No account, no servers, no tracking")
        }
    }

    private func benefitLabel(_ emoji: String, _ text: String) -> some View {
        HStack(alignment: .top) {
            Text(emoji)
            Text(text)
        }
    }

    @ViewBuilder
    private func planButton(
        _ product: Product, oneTime: Bool = false, badge: String? = nil
    ) -> some View {
        Button {
            Task {
                purchasing = true
                defer { purchasing = false }
                if (try? await store.purchase(product)) == true, store.isPro { dismiss() }
            }
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(product.displayName)
                    if let badge {
                        Text(badge).font(.caption2).foregroundStyle(.tint)
                    }
                }
                Spacer()
                Text(oneTime ? "\(product.displayPrice) once" : product.displayPrice)
                    .bold()
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(purchasing)
    }
}
