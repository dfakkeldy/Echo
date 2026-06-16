// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
import Foundation
@testable import Echo

@MainActor
struct BookSettingsOverrideStoreTests {

    let testID = "test-book-identifier"

    init() {
        // Clean up any leftover UserDefaults keys for the test ID.
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: BookPreferencesService.fontKey(for: testID))
        defaults.removeObject(forKey: BookPreferencesService.bookmarksInlineKey(for: testID))
        defaults.removeObject(forKey: BookPreferencesService.volumeBoostKey(for: testID))
    }

    // MARK: - Initial state

    @Test("Default overrides are all nil")
    func defaultOverridesNil() {
        let store = BookSettingsOverrideStore()

        #expect(store.bookFontOverride == nil)
        #expect(store.bookPlayBookmarksInlineOverride == nil)
        #expect(store.bookVolumeBoostOverride == nil)
    }

    // MARK: - Load

    @Test("loadOverrides sets font from UserDefaults")
    func loadFontOverride() {
        UserDefaults.standard.set("Lexend", forKey: BookPreferencesService.fontKey(for: testID))
        defer { UserDefaults.standard.removeObject(forKey: BookPreferencesService.fontKey(for: testID)) }

        let store = BookSettingsOverrideStore()
        store.loadOverrides(for: testID)

        #expect(store.bookFontOverride == "Lexend")
        #expect(store.bookPlayBookmarksInlineOverride == nil)
        #expect(store.bookVolumeBoostOverride == nil)
    }

    @Test("loadOverrides sets bookmarks-inline from UserDefaults")
    func loadBookmarksInlineOverride() {
        UserDefaults.standard.set("alwaysOn", forKey: BookPreferencesService.bookmarksInlineKey(for: testID))
        defer { UserDefaults.standard.removeObject(forKey: BookPreferencesService.bookmarksInlineKey(for: testID)) }

        let store = BookSettingsOverrideStore()
        store.loadOverrides(for: testID)

        #expect(store.bookPlayBookmarksInlineOverride == "alwaysOn")
    }

    @Test("loadOverrides sets volume-boost from UserDefaults")
    func loadVolumeBoostOverride() {
        UserDefaults.standard.set("alwaysOff", forKey: BookPreferencesService.volumeBoostKey(for: testID))
        defer { UserDefaults.standard.removeObject(forKey: BookPreferencesService.volumeBoostKey(for: testID)) }

        let store = BookSettingsOverrideStore()
        store.loadOverrides(for: testID)

        #expect(store.bookVolumeBoostOverride == "alwaysOff")
    }

    @Test("loadOverrides loads all three overrides at once")
    func loadAllOverrides() {
        UserDefaults.standard.set("OpenDyslexic", forKey: BookPreferencesService.fontKey(for: testID))
        UserDefaults.standard.set("alwaysOff", forKey: BookPreferencesService.bookmarksInlineKey(for: testID))
        UserDefaults.standard.set("alwaysOn", forKey: BookPreferencesService.volumeBoostKey(for: testID))
        defer {
            UserDefaults.standard.removeObject(forKey: BookPreferencesService.fontKey(for: testID))
            UserDefaults.standard.removeObject(forKey: BookPreferencesService.bookmarksInlineKey(for: testID))
            UserDefaults.standard.removeObject(forKey: BookPreferencesService.volumeBoostKey(for: testID))
        }

        let store = BookSettingsOverrideStore()
        store.loadOverrides(for: testID)

        #expect(store.bookFontOverride == "OpenDyslexic")
        #expect(store.bookPlayBookmarksInlineOverride == "alwaysOff")
        #expect(store.bookVolumeBoostOverride == "alwaysOn")
    }

    // MARK: - Persist

    @Test("persistFontOverride saves value to UserDefaults")
    func persistFontOverrideSaves() {
        let store = BookSettingsOverrideStore()

        store.persistFontOverride("Lexend", for: testID)
        #expect(UserDefaults.standard.string(forKey: BookPreferencesService.fontKey(for: testID)) == "Lexend")

        UserDefaults.standard.removeObject(forKey: BookPreferencesService.fontKey(for: testID))
    }

    @Test("persistFontOverride with nil removes UserDefaults key")
    func persistFontOverrideNilRemoves() {
        UserDefaults.standard.set("Lexend", forKey: BookPreferencesService.fontKey(for: testID))
        let store = BookSettingsOverrideStore()

        store.persistFontOverride(nil, for: testID)
        #expect(UserDefaults.standard.string(forKey: BookPreferencesService.fontKey(for: testID)) == nil)
    }

    @Test("persistBookmarksInlineOverride saves value to UserDefaults")
    func persistBookmarksInlineSaves() {
        let store = BookSettingsOverrideStore()

        store.persistBookmarksInlineOverride("alwaysOn", for: testID)
        #expect(UserDefaults.standard.string(forKey: BookPreferencesService.bookmarksInlineKey(for: testID)) == "alwaysOn")

        UserDefaults.standard.removeObject(forKey: BookPreferencesService.bookmarksInlineKey(for: testID))
    }

    @Test("persistVolumeBoostOverride saves value to UserDefaults")
    func persistVolumeBoostSaves() {
        let store = BookSettingsOverrideStore()

        store.persistVolumeBoostOverride("alwaysOff", for: testID)
        #expect(UserDefaults.standard.string(forKey: BookPreferencesService.volumeBoostKey(for: testID)) == "alwaysOff")

        UserDefaults.standard.removeObject(forKey: BookPreferencesService.volumeBoostKey(for: testID))
    }

    // MARK: - Resolution (via BookPreferencesService)

    @Test("resolvedAppFont uses global when override is nil")
    func resolutionFontFallbackToGlobal() {
        let result = BookPreferencesService.resolveAppFont(override: nil, globalFont: "OpenDyslexic")
        #expect(result == "OpenDyslexic")
    }

    @Test("resolvedAppFont uses override when set to non-inherit")
    func resolutionFontOverride() {
        let result = BookPreferencesService.resolveAppFont(override: "Lexend", globalFont: "System")
        #expect(result == "Lexend")
    }

    @Test("resolvedPlayBookmarksInline with alwaysOn ignores global")
    func resolutionBookmarksAlwaysOn() {
        let result = BookPreferencesService.resolvePlayBookmarksInline(override: "alwaysOn", globalValue: false)
        #expect(result == true)
    }

    @Test("resolvedVolumeBoost with alwaysOff ignores global")
    func resolutionVolumeBoostAlwaysOff() {
        let result = BookPreferencesService.resolveVolumeBoost(override: "alwaysOff", globalEnabled: true)
        #expect(result == false)
    }
}
