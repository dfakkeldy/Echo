// SPDX-License-Identifier: GPL-3.0-or-later
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

    // MARK: - Reader PDF view mode

    static func readerPDFViewModeKey(for audiobookID: String) -> String {
        "book_readerPDFViewMode_\(audiobookID)"
    }

    static func sourceDocumentBookmarkKey(for audiobookID: String) -> String {
        "book_sourceDocumentBookmark_\(audiobookID)"
    }

    /// Remembers the exact standalone document selected for a parent-keyed
    /// audio-less book. The database identity intentionally remains the parent
    /// URL so existing notes and timeline rows are preserved.
    static func saveSourceDocumentURL(
        _ url: URL?,
        for audiobookID: String,
        store: UserDefaults = .standard,
        makeBookmark: (URL) -> Data? = { LibraryAccess.makeBookmark(for: $0) }
    ) {
        let key = sourceDocumentBookmarkKey(for: audiobookID)
        guard let url else {
            store.removeObject(forKey: key)
            return
        }
        // A transient provider/bookmark failure must not destroy the last
        // working grant. Explicit nil is the only clearing operation.
        guard let bookmark = makeBookmark(url) else { return }
        store.set(bookmark, forKey: key)
    }

    static func sourceDocumentURL(
        for audiobookID: String,
        store: UserDefaults = .standard,
        resolveBookmark: (Data) -> (url: URL, isStale: Bool)? = {
            LibraryAccess.resolveURL(from: $0)
        }
    ) -> URL? {
        guard let bookmark = store.data(forKey: sourceDocumentBookmarkKey(for: audiobookID))
        else { return nil }
        guard let resolved = resolveBookmark(bookmark) else { return nil }
        if resolved.isStale {
            saveSourceDocumentURL(resolved.url, for: audiobookID, store: store)
        }
        return resolved.url
    }

    /// Returns a remembered document only when it is still a supported document
    /// in the requested container. This prevents stale preferences from routing
    /// one shelf record into another folder.
    static func reopenDocumentURL(
        for containerURL: URL, store: UserDefaults = .standard
    ) -> URL? {
        guard
            let documentURL = sourceDocumentURL(
                for: containerURL.absoluteString, store: store),
            PlaylistManager.isDocumentFile(documentURL),
            documentURL.deletingLastPathComponent().standardizedFileURL
                == containerURL.standardizedFileURL
        else { return nil }
        return documentURL
    }

    /// Persists the page⇄reflow choice for a PDF book. `nil` clears it (revert
    /// to the default). `store` is injectable for testing; production passes
    /// `.standard`.
    static func savePDFViewMode(
        _ mode: ReaderSurfaceMode?, for audiobookID: String, store: UserDefaults = .standard
    ) {
        let key = readerPDFViewModeKey(for: audiobookID)
        if let mode {
            store.set(mode.rawValue, forKey: key)
        } else {
            store.removeObject(forKey: key)
        }
    }

    /// Loads the persisted PDF view mode, falling back to `fallback` (default
    /// `.page`, per spec D1) when unset or unrecognised.
    static func loadPDFViewMode(
        for audiobookID: String, default fallback: ReaderSurfaceMode = .page,
        store: UserDefaults = .standard
    ) -> ReaderSurfaceMode {
        guard let raw = store.string(forKey: readerPDFViewModeKey(for: audiobookID)),
            let mode = ReaderSurfaceMode(rawValue: raw)
        else { return fallback }
        return mode
    }

    // MARK: - Sidecar / word-timing import summary

    nonisolated static func sidecarSummaryKey(for audiobookID: String) -> String {
        "book_sidecarSummary_\(audiobookID)"
    }

    /// Persists the alignment-sidecar import snapshot (Book Settings reads it to
    /// show whether read-along is word-level). `nil` clears it. `nonisolated`
    /// so `DocumentImportFinalizer` can write it from its off-main import task
    /// without an actor hop; `store` is injectable for testing.
    nonisolated static func saveSidecarSummary(
        _ summary: SidecarImportSummary?, for audiobookID: String,
        store: UserDefaults = .standard
    ) {
        let key = sidecarSummaryKey(for: audiobookID)
        guard let summary, let data = try? JSONEncoder().encode(summary) else {
            store.removeObject(forKey: key)
            return
        }
        store.set(data, forKey: key)
    }

    /// Loads the persisted sidecar summary, or `nil` if the book was imported
    /// before this feature (Book Settings then derives a best-effort line from
    /// the live `word_timing` rows).
    nonisolated static func loadSidecarSummary(
        for audiobookID: String, store: UserDefaults = .standard
    ) -> SidecarImportSummary? {
        guard let data = store.data(forKey: sidecarSummaryKey(for: audiobookID)) else {
            return nil
        }
        return try? JSONDecoder().decode(SidecarImportSummary.self, from: data)
    }

    // MARK: - Load

    static func loadOverrides(for audiobookID: String) -> (
        font: String?, bookmarks: String?, volumeBoost: String?
    ) {
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
