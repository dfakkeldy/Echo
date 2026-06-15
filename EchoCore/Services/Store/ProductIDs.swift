import Foundation

/// Single source of truth for StoreKit product identifiers + subscription group.
enum ProductIDs {
    static let lifetime = "com.echo.pro.unlock"  // existing non-consumable
    static let founders = "com.echo.pro.founders"  // limited-window non-consumable
    static let monthly = "com.echo.pro.monthly"  // auto-renewable
    static let yearly = "com.echo.pro.yearly"  // auto-renewable

    static let subscriptionGroupID = "Echo Pro"

    static let all: [String] = [lifetime, founders, monthly, yearly]
    static let nonConsumables: Set<String> = [lifetime, founders]
    static let subscriptions: Set<String> = [monthly, yearly]
}
