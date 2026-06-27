// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Single source of truth for StoreKit product identifiers.
/// Echo Pro offers auto-renewable subscriptions plus lifetime non-consumables.
enum ProductIDs {
    static let monthly = "com.echo.pro.monthly"
    static let yearly = "com.echo.pro.yearly"
    static let lifetime = "com.echo.pro.unlock"
    static let founders = "com.echo.pro.founders"

    static let subscriptions: [String] = [yearly, monthly]
    static let subscriptionIDs: Set<String> = [monthly, yearly]
    static let nonConsumables: Set<String> = [lifetime, founders]
    static let all: [String] = [yearly, monthly, lifetime, founders]
}
