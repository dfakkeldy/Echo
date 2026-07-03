// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct PaywallUXTests {
    @Test func paywallUsesSimpleUnlockSheetInsteadOfCarousel() throws {
        let source = try Self.source(path: "EchoCore/Views/Paywall/PaywallView.swift")

        #expect(source.contains("NavigationStack"))
        #expect(source.contains("ScrollView"))
        #expect(source.contains("VStack"))
        #expect(!source.contains("TabView"))
        #expect(!source.contains("PageTabViewStyle"))
        #expect(!source.localizedStandardContains("carousel"))
    }

    @Test func paywallOffersSubscriptionsLifetimeAndKeepsRestoreVisible() throws {
        let source = try Self.source(path: "EchoCore/Views/Paywall/PaywallView.swift")

        #expect(source.contains("ProductIDs.yearly"))
        #expect(source.contains("ProductIDs.monthly"))
        #expect(source.contains("ProductIDs.lifetime"))
        #expect(source.contains("The yearly plan can include a 7-day App Store trial"))
        #expect(source.contains("Lifetime"))
        #expect(source.contains("Restore Purchases"))
        #expect(source.contains("Terms"))
        #expect(source.contains("Privacy"))
        #expect(source.contains("FeedbackSupport.privacyPolicyURL"))
        #expect(!source.contains("kinnokilabs.com/apps/echo/privacy"))
        #expect(source.contains("Open source — you can build it yourself."))
        #expect(source.contains("Unlimited flashcards with FSRS scheduling"))
        #expect(source.contains("Apple Watch review sessions"))
        #expect(source.contains("Insights for listening and study streaks"))
        #expect(source.contains("Study export: Markdown, Anki decks, and chaptered .m4b"))
        #expect(source.contains("Audiobookshelf offline downloads and background sync"))
        let retiredNarrationClaim = [
            "unlimited",
            "on-device AI narration",
        ].joined(separator: " ")
        let retiredLibraryClaim = [
            "unlocks",
            "the",
            "whole",
            "library",
        ].joined(separator: " ")
        #expect(!source.localizedStandardContains(retiredNarrationClaim))
        #expect(!source.localizedStandardContains(retiredLibraryClaim))
    }

    @Test func paywallUsesStoreKitDisplayPricesForEveryPlan() throws {
        let source = try Self.source(path: "EchoCore/Views/Paywall/PaywallView.swift")
        let productIDs = try Self.source(path: "EchoCore/Services/Store/ProductIDs.swift")

        #expect(source.contains("product.displayPrice"))
        #expect(!source.contains("\"$"))
        #expect(Set(ProductIDs.all) == ProductIDs.subscriptionIDs.union(ProductIDs.nonConsumables))
        #expect(ProductIDs.subscriptionIDs == Set([ProductIDs.monthly, ProductIDs.yearly]))
        #expect(productIDs.contains("com.echo.pro.monthly"))
        #expect(productIDs.contains("com.echo.pro.yearly"))
        #expect(productIDs.contains("com.echo.pro.unlock"))
    }

    private static func source(path: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()

        while directory.path != "/" {
            let candidate = directory
                .deletingLastPathComponent()
                .appending(path: path)

            if FileManager.default.fileExists(atPath: candidate.path),
                let content = try? String(contentsOf: candidate, encoding: .utf8)
            {
                return content
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
