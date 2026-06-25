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

    @Test func paywallPromisesOneTimeNoSubscriptionAndKeepsRestoreVisible() throws {
        let source = try Self.source(path: "EchoCore/Views/Paywall/PaywallView.swift")

        #expect(source.contains("One-time — no subscription"))
        #expect(source.contains("Pay once, unlock forever. No subscription, no account."))
        #expect(source.contains("Restore Purchases"))
        #expect(source.contains("Terms"))
        #expect(source.contains("Privacy"))
        #expect(source.contains("Open source — you can build it yourself."))
    }

    @Test func paywallUsesStoreKitDisplayPricesForEveryUnlock() throws {
        let source = try Self.source(path: "EchoCore/Views/Paywall/PaywallView.swift")
        let productIDs = try Self.source(path: "EchoCore/Services/Store/ProductIDs.swift")

        #expect(source.contains("product.displayPrice"))
        #expect(!source.contains("\"$"))
        #expect(Set(ProductIDs.all) == ProductIDs.nonConsumables)
        #expect(productIDs.contains("non-consumable"))
        #expect(productIDs.contains("no subscriptions"))
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
