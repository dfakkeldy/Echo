import Foundation

enum FoundersWindow {
    /// Founders pricing offered until this date (UTC). Adjust at launch.
    static let endsAt = ISO8601DateFormatter().date(from: "2026-09-01T00:00:00Z")!
    static var isOpen: Bool { Date() < endsAt }
}
