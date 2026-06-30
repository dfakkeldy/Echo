// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import CryptoKit
    import Foundation
    import os.log

    /// Owns the user's pronunciation-override dictionary and persists it to
    /// Application Support as JSON. Per-book overrides live in
    /// `<directory>/books/<sha256(bookID)>.json` and are merged book-wins over
    /// the global map at `overrides(forBookID:)`.
    ///
    /// UI binds to this via `@Bindable`; `set`/`remove` mutate `entries` and
    /// write through atomically.
    @MainActor
    @Observable
    final class PronunciationOverrideStore {
        /// App-wide singleton. The Settings UI (`PronunciationDictionaryView`)
        /// and both NarrationService call sites (iOS PlayerModel, macOS batch)
        /// bind to this so edits take effect on the next chapter render.
        static let shared = PronunciationOverrideStore()

        private(set) var entries: [String: String] = [:]
        private let fileURL: URL
        /// Directory holding per-book override maps: `<base>/books/<sha256(bookID)>.json`.
        /// Kept separate from `global.json` so book-scoped fixes never leak across books.
        private let booksDirectory: URL
        /// Lazily-rehydrated per-book maps, keyed by the canonical audiobook id
        /// (`folderURL.absoluteString`). Loaded from disk on first read of a book.
        private var bookEntries: [String: [String: String]] = [:]
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
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            self.fileURL = directory.appendingPathComponent("global.json")
            self.booksDirectory = directory.appendingPathComponent("books", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: booksDirectory, withIntermediateDirectories: true)
            if let data = try? Data(contentsOf: fileURL),
                let decoded = try? JSONDecoder().decode([String: String].self, from: data)
            {
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

        /// Set a pronunciation that applies only to `bookID`. Book entries win over
        /// the global map at merge time (see `overrides(forBookID:)`).
        func set(word: String, ipa: String, forBookID bookID: String) throws {
            var book = loadedBookEntries(bookID)
            book[word] = ipa
            bookEntries[bookID] = book
            try persistBook(bookID)
        }

        /// Remove a per-book pronunciation. Leaves the global map and other books untouched.
        func remove(word: String, forBookID bookID: String) throws {
            var book = loadedBookEntries(bookID)
            book[word] = nil
            bookEntries[bookID] = book
            try persistBook(bookID)
        }

        /// The override map `NarrationService` applies before G2P. v1: global only.
        /// Echo's built-in defaults (e.g. the author's surname) are layered
        /// underneath the user's entries — a user override of the same word wins.
        func overrides() -> PronunciationOverrides {
            PronunciationOverrides.withBuiltInDefaults(entries)
        }

        /// Per-book overrides: the global map (with Echo's built-in defaults) merged
        /// with this book's entries, book-wins on conflict — the map `NarrationService`
        /// applies before G2P for a specific book.
        func overrides(forBookID bookID: String) -> PronunciationOverrides {
            let global = PronunciationOverrides.withBuiltInDefaults(entries).entries
            return PronunciationOverrides.merging(global: global, book: loadedBookEntries(bookID))
        }

        // MARK: - Private

        private func persist() throws {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
            logger.info("Saved \(self.entries.count, privacy: .public) pronunciation overrides.")
        }

        /// The on-disk file for a book's override map. SHA-256 of the canonical
        /// audiobook id keeps the filename stable and filesystem-safe regardless of
        /// the id's characters (URLs contain `/`, `:`, etc.).
        private func bookFileURL(_ bookID: String) -> URL {
            let hash = SHA256.hash(data: Data(bookID.utf8))
                .compactMap { String(format: "%02x", $0) }.joined()
            return booksDirectory.appendingPathComponent("\(hash).json")
        }

        /// Return this book's map, rehydrating from disk into the cache on first access.
        private func loadedBookEntries(_ bookID: String) -> [String: String] {
            if let cached = bookEntries[bookID] { return cached }
            let fileURL = bookFileURL(bookID)
            let loaded: [String: String]
            if FileManager.default.fileExists(atPath: fileURL.path) {
                do {
                    let data = try Data(contentsOf: fileURL)
                    loaded = try JSONDecoder().decode([String: String].self, from: data)
                } catch {
                    logger.error(
                        "Failed to decode per-book pronunciation overrides \(fileURL.lastPathComponent): \(error.localizedDescription)"
                    )
                    loaded = [:]
                }
            } else {
                loaded = [:]
            }
            bookEntries[bookID] = loaded
            return loaded
        }

        private func persistBook(_ bookID: String) throws {
            let data = try JSONEncoder().encode(bookEntries[bookID] ?? [:])
            try data.write(to: bookFileURL(bookID), options: .atomic)
            logger.info(
                "Saved \(self.bookEntries[bookID]?.count ?? 0, privacy: .public) per-book pronunciation overrides."
            )
        }
    }
#endif
