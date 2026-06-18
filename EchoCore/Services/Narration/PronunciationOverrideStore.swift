// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import Foundation
    import os.log

    /// Owns the user's pronunciation-override dictionary and persists it to
    /// Application Support as JSON. v1 ships a single global map; the per-book
    /// seam (`overrides(forBookID:)`) returns empty so the merge code in
    /// `NarrationService` is in place for a later per-book follow-up.
    ///
    /// UI binds to this via `@Bindable`; `set`/`remove` mutate `entries` and
    /// write through atomically.
    @MainActor
    @Observable
    final class PronunciationOverrideStore {
        private(set) var entries: [String: String] = [:]
        private let fileURL: URL
        private let logger = Logger(category: "PronunciationOverrides")

        /// Production initializer: persists under the shared Narration directory.
        /// Main-actor-isolated like the rest of the class; the Settings UI and
        /// NarrationService both construct it on the main actor.
        convenience init() {
            let dir = NarrationCache.directory()
                .appendingPathComponent("Pronunciations", isDirectory: true)
            self.init(directory: dir)
        }

        /// Test/overridable initializer: persists to `directory/global.json`.
        init(directory: URL) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.fileURL = directory.appendingPathComponent("global.json")
            if let data = try? Data(contentsOf: fileURL),
               let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
                self.entries = decoded
            }
        }

        func set(word: String, ipa: String) throws {
            entries[word] = ipa
            try persist()
        }

        func remove(word: String) throws {
            entries[word] = nil
            try persist()
        }

        /// The override map `NarrationService` applies before G2P. v1: global only.
        func overrides() -> PronunciationOverrides {
            PronunciationOverrides(entries: entries)
        }

        /// Per-book overrides — v1 returns empty (global map covers the common case;
        /// a character-name-per-book follow-up plugs in here).
        func overrides(forBookID bookID: String) -> PronunciationOverrides {
            PronunciationOverrides(entries: [:])
        }

        // MARK: - Private

        private func persist() throws {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
            logger.info("Saved \(self.entries.count, privacy: .public) pronunciation overrides.")
        }
    }
#endif
