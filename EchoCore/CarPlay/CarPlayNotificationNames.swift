import Foundation

// MARK: - CarPlay Notification Names

/// Notification names shared between CarPlayManager and any observer
/// (PlayerModel, app init, etc.). Defined in a file without a CarPlay import
/// so these symbols are available even on non-CarPlay platforms.
extension Notification.Name {
    /// Fired when the CarPlay bookmark button is tapped.
    static let carPlayAddBookmark = Notification.Name("carPlayAddBookmark")
    /// Fired when the CarPlay voice memo button is tapped.
    static let carPlayVoiceMemo = Notification.Name("carPlayVoiceMemo")
    /// Fired when the CarPlay mark-passage button is tapped.
    static let carPlayMarkPassage = Notification.Name("carPlayMarkPassage")
}
