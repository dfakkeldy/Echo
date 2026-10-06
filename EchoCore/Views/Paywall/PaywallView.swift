// SPDX-License-Identifier: GPL-3.0-or-later
import StoreKit
import SwiftUI

struct PaywallView: View {
    let context: PaywallContext
    @Environment(StoreManager.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var purchasing = false
    @State private var loadingProducts = false

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
                    // Echo Pro is a one-time unlock — no subscription.
                    if let lifetime = product(ProductIDs.lifetime) {
                        planButton(lifetime, oneTime: true, badge: "One-time — no subscription")
                    }
                    if product(ProductIDs.lifetime) == nil {
                        if loadingProducts {
                            ProgressView("Loading Echo Pro…")
                        } else {
                            Button("Retry Loading Echo Pro") {
                                Task { await loadProducts() }
                            }
                        }
                    }

                    Text("Pay once, unlock forever. No subscription, no account.")
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
                if store.products.isEmpty { await loadProducts() }
            }
        }
    }

    private func loadProducts() async {
        loadingProducts = true
        defer { loadingProducts = false }
        await store.requestProducts()
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 8) {
            benefitLabel("♾️", "Unlimited flashcards with FSRS scheduling")
            benefitLabel("⌚", "Apple Watch review sessions")
            benefitLabel("📊", "Insights for listening and study streaks")
            benefitLabel("📤", "Study export: Markdown, Anki decks, and chaptered .m4b")
            benefitLabel("⬇️", "Audiobookshelf offline downloads and background sync")
            benefitLabel("🔒", "Your library, with optional connected services")
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
                do {
                    if try await store.purchase(product), store.isPro { dismiss() }
                } catch {
                    store.recordStoreError(error)
                }
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
