// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Single source of truth for StoreKit product identifiers.
/// Echo Pro is a one-time unlock — non-consumables only, no subscriptions.
enum ProductIDs {
    static let lifetime = "com.echo.pro.unlock"  // one-time Pro unlock (non-consumable)
    static let founders = "com.echo.pro.founders"  // limited-window non-consumable

    static let all: [String] = [lifetime, founders]
    static let nonConsumables: Set<String> = [lifetime, founders]
}
