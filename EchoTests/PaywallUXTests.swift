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
        #expect(source.contains("Subscriptions can include App Store trials"))
        #expect(source.contains("Lifetime"))
        #expect(source.contains("Restore Purchases"))
        #expect(source.contains("Terms"))
        #expect(source.contains("Privacy"))
        #expect(source.contains("FeedbackSupport.privacyPolicyURL"))
        #expect(!source.contains("kinnokilabs.com/apps/echo/privacy"))
        #expect(source.contains("Open source — you can build it yourself."))
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
