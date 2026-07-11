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
        // Per-book wins.
        try store.set(word: "Gandalf", ipa: "ɡˈændælf", forBookID: "file:///Books/LOTR/")

        let merged = store.overrides(forBookID: "file:///Books/LOTR/")
        #expect(merged.entries["Gandalf"] == "ɡˈændælf")
        // A different book sees only the global value.
        let other = store.overrides(forBookID: "file:///Books/Other/")
        #expect(other.entries["Gandalf"] == "ɡˈændɑːlf")
    }

    @MainActor
    @Test func perBookEntryCaseInsensitivelyWinsOverBuiltInDefault() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = PronunciationOverrideStore(directory: tmp)
        let bookID = "file:///Books/Startable/"
        try store.set(word: "STARTABLE", ipa: "stˈɑɹtəbəl", forBookID: bookID)

        let merged = store.overrides(forBookID: bookID)
        let matchingKeys = merged.entries.keys.filter { $0.lowercased() == "startable" }
        #expect(matchingKeys.count == 1)
        #expect(merged.apply(to: "startable") == "[startable](/stˈɑɹtəbəl/)")
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

    // MARK: - Occurrence override tests

    @MainActor
    @Test func occurrenceEntriesRoundTripThroughDisk() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let bookID = "file:///Books/LOTR/"
        let store = PronunciationOverrideStore(directory: tmp)
        try store.setOccurrence(
            word: "content",
            ipa: "kˈɑntɛnt",
            forBookID: bookID,
            blockID: "blk1",
            wordStart: 2,
            wordEnd: 2)

        let reloaded = PronunciationOverrideStore(directory: tmp)
        let out = reloaded.occurrenceOverrides(forBookID: bookID)
            .apply(to: "Useful story content lives here.", blockID: "blk1")

        #expect(out == "Useful story [content](/kˈɑntɛnt/) lives here.")
    }

    @MainActor
    @Test func occurrenceEntryUpsertsSameLocation() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = PronunciationOverrideStore(directory: tmp)
        let bookID = "file:///Books/LOTR/"
        try store.setOccurrence(
            word: "content", ipa: "kˈɑntɛnt",
            forBookID: bookID, blockID: "blk1", wordStart: 1, wordEnd: 1)
        try store.setOccurrence(
            word: "content", ipa: "kəntˈɛnt",
            forBookID: bookID, blockID: "blk1", wordStart: 1, wordEnd: 1)

        let out = store.occurrenceOverrides(forBookID: bookID)
            .apply(to: "The content stayed.", blockID: "blk1")

        #expect(out == "The [content](/kəntˈɛnt/) stayed.")
    }

    // MARK: - IPA entry validation

    @MainActor
    @Test func rejectsGlobalOverrideWithUnsupportedIPACharacters() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = PronunciationOverrideStore(directory: tmp)
        // "guːɡəl" starts with ASCII "g" (U+0067), a look-alike for IPA "ɡ"
        // (U+0261) that the Kokoro vocab can't encode. Must be rejected at entry so
        // it can't silently brick the book's next chapter render.
        #expect(throws: PronunciationOverrideError.self) {
            try store.set(word: "Google", ipa: "guːɡəl")
        }
        #expect(store.entries["Google"] == nil)  // nothing persisted

        // The all-IPA spelling is accepted and stored.
        try store.set(word: "Google", ipa: "ɡuːɡəl")
        #expect(store.entries["Google"] == "ɡuːɡəl")
    }

    @MainActor
    @Test func rejectsPerBookAndOccurrenceOverridesWithUnsupportedIPA() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = PronunciationOverrideStore(directory: tmp)
        let bookID = "file:///Books/X/"
        // "hɝ" uses ɝ (U+025D r-colored schwa), common in dictionaries but absent
        // from the Kokoro vocab. Both the per-book and occurrence entry paths must
        // reject it and persist nothing.
        #expect(throws: PronunciationOverrideError.self) {
            try store.set(word: "her", ipa: "hɝ", forBookID: bookID)
        }
        #expect(throws: PronunciationOverrideError.self) {
            try store.setOccurrence(
                word: "her", ipa: "hɝ",
                forBookID: bookID, blockID: "b", wordStart: 0, wordEnd: 0)
        }
        #expect(store.overrides(forBookID: bookID).entries["her"] == nil)
        #expect(
            store.occurrenceOverrides(forBookID: bookID).apply(to: "her book", blockID: "b")
                == "her book")
    }
}
