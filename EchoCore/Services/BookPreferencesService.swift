import Foundation

/// Encapsulates per-book UserDefaults persistence and override-resolution logic
/// so PlayerModel stays thin.
struct BookPreferencesService {

    // MARK: - Keys

    static func fontKey(for audiobookID: String) -> String {
        "book_appFont_\(audiobookID)"
    }

    static func bookmarksInlineKey(for audiobookID: String) -> String {
        "book_bookmarksInline_\(audiobookID)"
    }

    static func volumeBoostKey(for audiobookID: String) -> String {
        "book_volumeBoost_\(audiobookID)"
    }

    // MARK: - Reader settings

    static func readerFontSizeKey(for audiobookID: String) -> String {
        "book_readerFontSize_\(audiobookID)"
    }

    static func readerLineSpacingKey(for audiobookID: String) -> String {
        "book_readerLineSpacing_\(audiobookID)"
    }

    static func readerCardTintKey(for audiobookID: String) -> String {
        "book_readerCardTint_\(audiobookID)"
    }

    // MARK: - Load

    static func loadOverrides(for audiobookID: String) -> (font: String?, bookmarks: String?, volumeBoost: String?) {
        let defaults = UserDefaults.standard
        return (
            font: defaults.string(forKey: fontKey(for: audiobookID)),
            bookmarks: defaults.string(forKey: bookmarksInlineKey(for: audiobookID)),
            volumeBoost: defaults.string(forKey: volumeBoostKey(for: audiobookID))
        )
    }

    // MARK: - Save

    static func saveFontOverride(_ value: String?, for audiobookID: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: fontKey(for: audiobookID))
        } else {
            UserDefaults.standard.removeObject(forKey: fontKey(for: audiobookID))
        }
    }

    static func saveBookmarksInlineOverride(_ value: String?, for audiobookID: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: bookmarksInlineKey(for: audiobookID))
        } else {
            UserDefaults.standard.removeObject(forKey: bookmarksInlineKey(for: audiobookID))
        }
    }

    static func saveVolumeBoostOverride(_ value: String?, for audiobookID: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: volumeBoostKey(for: audiobookID))
        } else {
            UserDefaults.standard.removeObject(forKey: volumeBoostKey(for: audiobookID))
        }
    }

    // MARK: - Resolution

    static func resolveAppFont(override: String?, globalFont: String?) -> String {
        if let override, override != "inherit" {
            return override
        }
        return globalFont ?? SettingsManager.Defaults.appFont
    }

    static func resolvePlayBookmarksInline(override: String?, globalValue: Bool?) -> Bool {
        if let override {
            if override == "alwaysOn" { return true }
            if override == "alwaysOff" { return false }
        }
        return globalValue ?? SettingsManager.Defaults.playBookmarksInline
    }

    static func resolveVolumeBoost(override: String?, globalEnabled: Bool) -> Bool {
        if let override {
            if override == "alwaysOn" { return true }
            if override == "alwaysOff" { return false }
        }
        return globalEnabled
    }
}
