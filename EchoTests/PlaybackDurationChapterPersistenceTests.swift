// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import Foundation
    import Testing

    @testable import Echo

    @MainActor
    @Suite struct PlaybackDurationChapterPersistenceTests {
        @Test func fallbackChapterUsesLoadedAudioDuration() async throws {
            let db = try DatabaseService(inMemory: ())
            let audioURL = try await SilentAudioFixture.makeSilentM4A(seconds: 2)
            defer { try? FileManager.default.removeItem(at: audioURL) }

            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("fallback-duration-\(UUID().uuidString)", isDirectory: true)
            let audiobookID = folder.absoluteString
            TimelineIngestionService.persistAudiobook(
                db: db,
                folderURL: folder,
                tracks: [Track(url: audioURL, title: "No Embedded Chapters")],
                duration: nil)

            let state = PlaybackState()
            state.folderURL = folder
            state.tracks = [Track(url: audioURL, title: "No Embedded Chapters")]
            state.currentIndex = 0

            let audioEngine = AudioEngine()
            audioEngine.configureAudioSession()
            audioEngine.replaceCurrentItem(with: audioURL)
            defer { audioEngine.cleanup() }

            let coordinator = ChapterLoadingCoordinator()
            coordinator.state = state
            coordinator.audioEngine = audioEngine
            coordinator.persistence = Persistence(defaults: Self.makeDefaults())
            coordinator.databaseServiceProvider = { db }

            await coordinator.loadChaptersForCurrentItem()

            let chapter = try #require(state.chapters.first)
            #expect(chapter.startSeconds == 0)
            #expect(abs(chapter.endSeconds - 2) < 0.25)

            let records = try ChapterDAO(db: db.writer).chapters(for: audiobookID)
            #expect(records.count == 1)
            #expect(abs(records[0].endSeconds - 2) < 0.25)
        }

        @Test func trackSwitchDoesNotReplaceWholeBookChapterRecords() async throws {
            let db = try DatabaseService(inMemory: ())
            let firstURL = try await SilentAudioFixture.makeSilentM4A(seconds: 1)
            let secondURL = try await SilentAudioFixture.makeSilentM4A(seconds: 1)
            defer {
                try? FileManager.default.removeItem(at: firstURL)
                try? FileManager.default.removeItem(at: secondURL)
            }

            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("multi-track-chapters-\(UUID().uuidString)", isDirectory: true)
            let audiobookID = folder.absoluteString
            let tracks = [
                Track(url: firstURL, title: "Track One"),
                Track(url: secondURL, title: "Track Two"),
            ]
            TimelineIngestionService.persistAudiobook(
                db: db, folderURL: folder, tracks: tracks, duration: nil)
            TimelineIngestionService.persistChapters(
                db: db,
                audiobookID: audiobookID,
                chapters: [
                    Chapter(
                        index: 0, title: "Whole Book One", startSeconds: 0, endSeconds: 1,
                        isEnabled: true),
                    Chapter(
                        index: 1, title: "Whole Book Two", startSeconds: 0, endSeconds: 1,
                        isEnabled: true),
                ])

            let state = PlaybackState()
            state.folderURL = folder
            state.tracks = tracks
            state.currentIndex = 1

            let audioEngine = AudioEngine()
            audioEngine.configureAudioSession()
            audioEngine.replaceCurrentItem(with: secondURL)
            defer { audioEngine.cleanup() }

            let coordinator = ChapterLoadingCoordinator()
            coordinator.state = state
            coordinator.audioEngine = audioEngine
            coordinator.persistence = Persistence(defaults: Self.makeDefaults())
            coordinator.databaseServiceProvider = { db }

            await coordinator.loadChaptersForCurrentItem()

            let records = try ChapterDAO(db: db.writer).chapters(for: audiobookID)
            #expect(records.map(\.title) == ["Whole Book One", "Whole Book Two"])
        }

        @Test func chapterRecordsPreserveFallbackDurations() {
            let records = TimelineIngestionService.chapterRecords(
                from: [
                    Chapter(index: 0, title: "MP3 One", startSeconds: 0, endSeconds: 307.294125),
                    Chapter(index: 1, title: "MP3 Two", startSeconds: 0, endSeconds: 177.52),
                ],
                audiobookID: "book")

            #expect(records.map(\.endSeconds) == [307.294125, 177.52])
        }

        private static func makeDefaults() -> UserDefaults {
            let suiteName = "PlaybackDurationChapterPersistenceTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName) ?? .standard
            defaults.removePersistentDomain(forName: suiteName)
            return defaults
        }
    }
#endif
