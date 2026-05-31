import Foundation
import Observation

/// Stores and persists per-book settings overrides (font, bookmarks-inline, volume boost).
/// Each override defaults to `nil` ("inherit global") and is loaded/stored via
/// `BookPreferencesService` keyed by the audiobook's folder URL string.
@Observable
final class BookSettingsOverrideStore {

    // MARK: - Override values

    var bookFontOverride: String? = nil
    var bookPlayBookmarksInlineOverride: String? = nil
    var bookVolumeBoostOverride: String? = nil

    // MARK: - Load

    func loadOverrides(for audiobookID: String) {
        let overrides = BookPreferencesService.loadOverrides(for: audiobookID)
        bookFontOverride = overrides.font
        bookPlayBookmarksInlineOverride = overrides.bookmarks
        bookVolumeBoostOverride = overrides.volumeBoost
    }

    // MARK: - Persist

    func persistFontOverride(_ value: String?, for audiobookID: String) {
        BookPreferencesService.saveFontOverride(value, for: audiobookID)
    }

    func persistBookmarksInlineOverride(_ value: String?, for audiobookID: String) {
        BookPreferencesService.saveBookmarksInlineOverride(value, for: audiobookID)
    }

    func persistVolumeBoostOverride(_ value: String?, for audiobookID: String) {
        BookPreferencesService.saveVolumeBoostOverride(value, for: audiobookID)
    }
}
