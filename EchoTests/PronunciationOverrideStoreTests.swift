// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
import Foundation
@testable import Echo

@Suite struct PronunciationOverrideStoreTests {

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
        let ovr = store.overrides() // used by NarrationService
        #expect(ovr.entries["redis"] == "ˈɹiːdɪs")
    }
}
