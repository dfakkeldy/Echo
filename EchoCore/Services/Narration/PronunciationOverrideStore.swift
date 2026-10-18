// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import CryptoKit
    import Foundation
    import os.log

    /// Thrown when a user-entered pronunciation can't be represented by the Kokoro
    /// phoneme vocab. Surfaced by the Settings UI so a typo is corrected at entry
    /// time instead of aborting a whole chapter render later (see
    /// `PronunciationPlanner` / `KokoroPhonemeVocab.validatedIDs`).
    enum PronunciationOverrideError: LocalizedError, Equatable {
        case unsupportedIPA(characters: String)

        var errorDescription: String? {
            switch self {
            case .unsupportedIPA(let characters):
                return
                    "These characters aren't valid IPA phonemes: \(characters). Enter IPA symbols only — e.g. kuːbərˈnɛtɪs. A common mix-up is typing the ASCII letter “g” instead of the IPA “ɡ”."
            }
        }
    }

    /// The pair of pronunciation-override closures a batch/render path injects into
    /// `NarrationService`. Bundling BOTH behind one value keeps the iOS player and
    /// the macOS batch path wired identically: a regression that supplies the
    /// dictionary but stubs the per-occurrence corrections to `.empty` on one
    /// platform — the "settings that lie" divergence — becomes a single-source
    /// change that `narrationOverrideClosures(forBookID:)`'s test guards.
    struct NarrationOverrideClosures {
        let overrides: () -> PronunciationOverrides
        let occurrenceOverrides: () -> PronunciationOccurrenceOverrides
    }

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
        /// Directory holding per-book occurrence corrections:
        /// `<base>/occurrences/<sha256(bookID)>.json`.
        private let occurrencesDirectory: URL
        /// Lazily-rehydrated per-book maps, keyed by the canonical audiobook id
        /// (`folderURL.absoluteString`). Loaded from disk on first read of a book.
        private var bookEntries: [String: [String: String]] = [:]
        /// Lazily-rehydrated per-book occurrence corrections, keyed by audiobook id.
        private var occurrenceEntries: [String: [PronunciationOccurrenceOverride]] = [:]
        private let logger = Logger(category: "PronunciationOverrides")
        /// The Kokoro phoneme vocab, loaded once to validate entered IPA. `nil` if
        /// the bundled vocab resource can't load — in which case entry validation
        /// is skipped (fail open) so a missing bundle never blocks the user; the
        /// render path still degrades gracefully. Not observable UI state.
        @ObservationIgnored
        private lazy var phonemeVocab: KokoroPhonemeVocab? = try? KokoroPhonemeVocab()

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
            self.occurrencesDirectory = directory.appendingPathComponent(
                "occurrences",
                isDirectory: true)
            try? FileManager.default.createDirectory(
                at: booksDirectory, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(
                at: occurrencesDirectory, withIntermediateDirectories: true)
            if let data = try? Data(contentsOf: fileURL),
                let decoded = try? JSONDecoder().decode([String: String].self, from: data)
            {
                self.entries = decoded
            }
        }

        func set(word: String, ipa: String) throws {
            try validateIPA(ipa)
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
            try validateIPA(ipa)
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

        /// Set a pronunciation for one source occurrence. Replaces any existing
        /// correction at the same block + word-index span for this book.
        func setOccurrence(
            word: String,
            ipa: String,
            forBookID bookID: String,
            blockID: String,
            wordStart: Int,
            wordEnd: Int
        ) throws {
            guard wordStart >= 0, wordEnd >= wordStart else { return }
            try validateIPA(ipa)
            var book = loadedOccurrenceEntries(bookID)
            book.removeAll {
                $0.blockID == blockID && $0.wordStart == wordStart && $0.wordEnd == wordEnd
            }
            book.append(
                PronunciationOccurrenceOverride(
                    blockID: blockID,
                    wordStart: wordStart,
                    wordEnd: wordEnd,
                    word: word,
                    ipa: ipa))
            occurrenceEntries[bookID] = book
            try persistOccurrences(bookID)
        }

        /// Remove a single source-position pronunciation. Leaves broader
        /// global/book pronunciations untouched.
        func removeOccurrence(
            forBookID bookID: String,
            blockID: String,
            wordStart: Int,
            wordEnd: Int
        ) throws {
            var book = loadedOccurrenceEntries(bookID)
            book.removeAll {
                $0.blockID == blockID && $0.wordStart == wordStart && $0.wordEnd == wordEnd
            }
            occurrenceEntries[bookID] = book
            try persistOccurrences(bookID)
        }

        /// The global override map `NarrationService` applies before G2P.
        /// Echo's built-in defaults (e.g. the author's surname) are layered
        /// underneath the user's entries — a user override of the same word wins.
        func overrides() -> PronunciationOverrides {
            PronunciationOverrides.withBuiltInDefaults(entries)
        }

        /// Per-book overrides: the global map (with Echo's built-in defaults) merged
        /// with this book's entries, book-wins on conflict — the map `NarrationService`
        /// applies before G2P for a specific book.
        func overrides(forBookID bookID: String) -> PronunciationOverrides {
            let global = PronunciationOverrides.withBuiltInDefaults(entries)
            return PronunciationOverrides.merging(global: global, book: loadedBookEntries(bookID))
        }

        /// Source-position corrections for a book. Applied before global/book
        /// dictionary overrides so one accepted occurrence can beat a broader rule.
        func occurrenceOverrides(forBookID bookID: String) -> PronunciationOccurrenceOverrides {
            PronunciationOccurrenceOverrides(entries: loadedOccurrenceEntries(bookID))
        }

        /// Builds the pronunciation-override closures for `bookID` that a batch or
        /// render path injects into `NarrationService`. Both the global/book
        /// dictionary AND the per-occurrence corrections are wired from this store,
        /// so no caller can silently ship one without the other (see the type doc).
        /// The closures read the live store at call time — like the inline closures
        /// they replace — so later edits take effect on the next chapter render.
        func narrationOverrideClosures(forBookID bookID: String) -> NarrationOverrideClosures {
            NarrationOverrideClosures(
                overrides: { self.overrides(forBookID: bookID) },
                occurrenceOverrides: { self.occurrenceOverrides(forBookID: bookID) })
        }

        // MARK: - Private

        /// Rejects a pronunciation whose IPA contains characters the Kokoro vocab
        /// can't encode, so the failure surfaces at entry time in the UI instead of
        /// aborting the book's next chapter render (the entered IPA is passed
        /// through to Kokoro verbatim via Misaki `[word](/ipa/)` link syntax). Fails
        /// open when the vocab resource is unavailable.
        private func validateIPA(_ ipa: String) throws {
            guard let phonemeVocab else { return }
            let unsupported = phonemeVocab.unsupportedCharacters(in: ipa)
            guard unsupported.isEmpty else {
                throw PronunciationOverrideError.unsupportedIPA(characters: String(unsupported))
            }
        }

        private func persist() throws {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
            logger.info("Saved \(self.entries.count, privacy: .public) pronunciation overrides.")
        }

        /// The on-disk file for a book's override map. SHA-256 of the canonical
        /// audiobook id keeps the filename stable and filesystem-safe regardless of
        /// the id's characters (URLs contain `/`, `:`, etc.).
        private func bookFileURL(_ bookID: String) -> URL {
            booksDirectory.appendingPathComponent("\(hashedBookID(bookID)).json")
        }

        private func occurrencesFileURL(_ bookID: String) -> URL {
            occurrencesDirectory.appendingPathComponent("\(hashedBookID(bookID)).json")
        }

        private func hashedBookID(_ bookID: String) -> String {
            SHA256.hash(data: Data(bookID.utf8))
                .compactMap { String(format: "%02x", $0) }.joined()
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

        private func loadedOccurrenceEntries(_ bookID: String) -> [PronunciationOccurrenceOverride]
        {
            if let cached = occurrenceEntries[bookID] { return cached }
            let fileURL = occurrencesFileURL(bookID)
            let loaded: [PronunciationOccurrenceOverride]
            if FileManager.default.fileExists(atPath: fileURL.path) {
                do {
                    let data = try Data(contentsOf: fileURL)
                    loaded = try JSONDecoder().decode(
                        [PronunciationOccurrenceOverride].self,
                        from: data)
                } catch {
                    logger.error(
                        "Failed to decode per-occurrence pronunciation overrides \(fileURL.lastPathComponent): \(error.localizedDescription)"
                    )
                    loaded = []
                }
            } else {
                loaded = []
            }
            occurrenceEntries[bookID] = loaded
            return loaded
        }

        private func persistBook(_ bookID: String) throws {
            let data = try JSONEncoder().encode(bookEntries[bookID] ?? [:])
            try data.write(to: bookFileURL(bookID), options: .atomic)
            logger.info(
                "Saved \(self.bookEntries[bookID]?.count ?? 0, privacy: .public) per-book pronunciation overrides."
            )
        }

        private func persistOccurrences(_ bookID: String) throws {
            let data = try JSONEncoder().encode(occurrenceEntries[bookID] ?? [])
            try data.write(to: occurrencesFileURL(bookID), options: .atomic)
            logger.info(
                "Saved \(self.occurrenceEntries[bookID]?.count ?? 0, privacy: .public) per-occurrence pronunciation overrides."
            )
        }
    }
#endif
