// SPDX-License-Identifier: GPL-3.0-or-later
import StoreKit
import SwiftUI

struct PaywallView: View {
    let context: PaywallContext
    @Environment(StoreManager.self) private var store
    @Environment(\.dismiss) private var dismiss
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
                        planButton(yearly, badge: badge(for: yearly), priceSuffix: "/ year")
                    }
                    if let monthly = product(ProductIDs.monthly) {
                        planButton(monthly, badge: badge(for: monthly), priceSuffix: "/ month")
                    }
                    if let lifetime = product(ProductIDs.lifetime) {
                        planButton(lifetime, badge: "Lifetime", priceSuffix: "once")
                    }
                    if FoundersWindow.isOpen, let founders = product(ProductIDs.founders) {
                        planButton(founders, badge: "Founders — limited time", priceSuffix: "once")
                    }

                    Text(
                        "Subscriptions can include App Store trials. Lifetime stays available when you're ready to own Echo forever."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

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
                            destination: FeedbackSupport.privacyPolicyURL
                        )
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
            }
        }
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 8) {
            benefitLabel("♾️", "Unlimited flashcards with FSRS spaced repetition")
            benefitLabel("🗣️", "Unlimited on-device AI narration")
            benefitLabel("📊", "Insights — listening & study streaks")
            benefitLabel("📤", "Export any book as a chaptered .m4b audiobook")
            benefitLabel("🔒", "No Echo account or servers, no tracking")
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
        _ product: Product, badge: String? = nil, priceSuffix: String? = nil
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
                Text(priceText(for: product, suffix: priceSuffix))
                    .bold()
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(purchasing)
    }

    private func badge(for product: Product) -> String {
        guard product.subscription?.introductoryOffer?.paymentMode == .freeTrial else {
            return product.id == ProductIDs.yearly ? "Yearly" : "Monthly"
        }

        return product.id == ProductIDs.yearly ? "Yearly trial" : "Monthly trial"
    }

    private func priceText(for product: Product, suffix: String?) -> String {
        guard let suffix else { return product.displayPrice }
        return "\(product.displayPrice) \(suffix)"
    }
}
