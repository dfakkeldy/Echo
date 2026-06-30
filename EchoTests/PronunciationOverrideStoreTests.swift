// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct PronunciationOverrideStoreTests {

    // MARK: - Global override tests

    @MainActor
    @Test func roundTripsEntriesThroughDisk() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = PronunciationOverrideStore(directory: tmp)
        try store.set(word: "Kubernetes", ipa: "kuːbərˈnɛtɪs")

        // Re-load from the same directory → entry persists.
        let reloaded = PronunciationOverrideStore(directory: tmp)
        #expect(reloaded.entries["Kubernetes"] == "kuːbərˈnɛtɪs")
    }

    @MainActor
    @Test func deleteRemovesEntry() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = PronunciationOverrideStore(directory: tmp)
        try store.set(word: "docker", ipa: "ˈdɒkə")
        try store.remove(word: "docker")
        #expect(store.entries["docker"] == nil)
    }

    @MainActor
    @Test func overridingMergesForG2P() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = PronunciationOverrideStore(directory: tmp)
        try store.set(word: "redis", ipa: "ˈɹiːdɪs")
        let ovr = store.overrides()  // used by NarrationService
        #expect(ovr.entries["redis"] == "ˈɹiːdɪs")
    }

    // MARK: - Per-book override tests

    @MainActor
    @Test func perBookEntryWinsOverGlobalInMergedOverrides() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = PronunciationOverrideStore(directory: tmp)
        try store.set(word: "Gandalf", ipa: "ɡˈændɑːlf")  // global
        try store.set(word: "Gandalf", ipa: "ɡˈændælf", forBookID: "file:///Books/LOTR/")  // per-book wins

        let merged = store.overrides(forBookID: "file:///Books/LOTR/")
        #expect(merged.entries["Gandalf"] == "ɡˈændælf")
        // A different book sees only the global value.
        let other = store.overrides(forBookID: "file:///Books/Other/")
        #expect(other.entries["Gandalf"] == "ɡˈændɑːlf")
    }

    @MainActor
    @Test func perBookEntriesRoundTripThroughDisk() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = PronunciationOverrideStore(directory: tmp)
        try store.set(word: "Frodo", ipa: "frˈoʊdoʊ", forBookID: "file:///Books/LOTR/")

        // A fresh store over the same directory rehydrates the per-book map lazily.
        let reloaded = PronunciationOverrideStore(directory: tmp)
        #expect(reloaded.overrides(forBookID: "file:///Books/LOTR/").entries["Frodo"] == "frˈoʊdoʊ")
    }

    @MainActor
    @Test func removeForBookDropsOnlyThatBooksEntry() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = PronunciationOverrideStore(directory: tmp)
        try store.set(word: "Bree", ipa: "briː", forBookID: "file:///Books/LOTR/")
        try store.set(word: "Bree", ipa: "brˈeɪ", forBookID: "file:///Books/Other/")
        try store.remove(word: "Bree", forBookID: "file:///Books/LOTR/")

        #expect(store.overrides(forBookID: "file:///Books/LOTR/").entries["Bree"] == nil)
        #expect(store.overrides(forBookID: "file:///Books/Other/").entries["Bree"] == "brˈeɪ")
    }
}
