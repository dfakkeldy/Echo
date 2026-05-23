import Foundation
import Testing
@testable import Orbit_Audiobooks

@MainActor
struct WatchStateContextBuilderTests {

    // MARK: - Playback state

    @Test("playback state values are passed through to context")
    func playbackStateValues() {
        var snap = WatchStateSnapshot()
        snap.isPlaying = true
        snap.progressFraction = 0.75
        snap.currentPlaybackTime = 120.5
        snap.currentTrackId = "track-1"
        snap.folderKey = "/books/dune"
        snap.bookmarkStorageKey = "/books/dune"

        let ctx = WatchStateContextBuilder.build(from: snap)

        #expect(ctx["isPlaying"] as? Bool == true)
        #expect(ctx["progressFraction"] as? Double == 0.75)
        #expect(ctx["currentTime"] as? TimeInterval == 120.5)
        #expect(ctx["trackId"] as? String == "track-1")
        #expect(ctx["folderKey"] as? String == "/books/dune")
        #expect(ctx["bookmarkStorageKey"] as? String == "/books/dune")
    }

    @Test("missing track ID is omitted from context")
    func missingTrackIdOmitted() {
        var snap = WatchStateSnapshot()
        snap.currentTrackId = nil

        let ctx = WatchStateContextBuilder.build(from: snap)

        #expect(ctx["trackId"] == nil)
    }

    // MARK: - Title

    @Test("title uses chapter name when 2+ chapters and subtitle is set")
    func titleWithChaptersAndSubtitle() {
        var snap = WatchStateSnapshot()
        snap.chapterCount = 5
        snap.currentSubtitle = "The Revelation"
        snap.currentChapterIndex = 2
        snap.currentTitle = "Dune"

        let ctx = WatchStateContextBuilder.build(from: snap)

        #expect(ctx["title"] as? String == "The Revelation")
    }

    @Test("title falls back to generated chapter label when subtitle is empty")
    func titleWithChaptersAndEmptySubtitle() {
        var snap = WatchStateSnapshot()
        snap.chapterCount = 3
        snap.currentSubtitle = ""
        snap.currentChapterIndex = 0

        let ctx = WatchStateContextBuilder.build(from: snap)

        #expect(ctx["title"] as? String == "Chapter 1")
    }

    @Test("title uses track title when fewer than 2 chapters")
    func titleWithoutChapters() {
        var snap = WatchStateSnapshot()
        snap.chapterCount = 1
        snap.currentTitle = "Dune.m4b"

        let ctx = WatchStateContextBuilder.build(from: snap)

        #expect(ctx["title"] as? String == "Dune.m4b")
    }

    // MARK: - Total progress

    @Test("total progress uses time-based computation when duration is available")
    func totalProgressTimeBased() {
        var snap = WatchStateSnapshot()
        snap.durationSeconds = 3600
        snap.currentPlaybackTime = 1800

        let ctx = WatchStateContextBuilder.build(from: snap)

        #expect(ctx["totalProgressFraction"] as? Double == 0.5)
        #expect(ctx["totalBookDuration"] as? Double == 3600)
    }

    @Test("total progress clamps to [0, 1]")
    func totalProgressClamped() {
        var snap = WatchStateSnapshot()
        snap.durationSeconds = 100
        snap.currentPlaybackTime = 150

        let ctx = WatchStateContextBuilder.build(from: snap)

        #expect(ctx["totalProgressFraction"] as? Double == 1.0)
    }

    @Test("total progress falls back to track index when no duration")
    func totalProgressTrackBased() {
        var snap = WatchStateSnapshot()
        snap.durationSeconds = nil
        snap.trackCount = 10
        snap.currentIndex = 2
        snap.progressFraction = 0.5

        let ctx = WatchStateContextBuilder.build(from: snap)

        let fraction = ctx["totalProgressFraction"] as? Double ?? -1
        #expect(fraction == (2.0 + 0.5) / 10.0)
    }

    // MARK: - Settings

    @Test("settings values are passed through to context")
    func settingsValues() {
        var snap = WatchStateSnapshot()
        snap.crownAction = "scrub"
        snap.isHapticFeedbackEnabled = false
        snap.watchQuickBookmarkTimeoutSeconds = 10
        snap.loopModeRawValue = "bookmark"
        snap.playbackSpeed = 1.5
        snap.watchPage1Data = Data([0x01])
        snap.watchPage2Data = Data([0x02])
        snap.linearBarMode = "chapter"
        snap.linearBarHidden = true
        snap.circularRingMode = "total"
        snap.circularRingHidden = true
        snap.watchArtworkLayout = "compact"
        snap.watchBackgroundStyle = "solid"

        let ctx = WatchStateContextBuilder.build(from: snap)

        #expect(ctx["crownAction"] as? String == "scrub")
        #expect(ctx["isHapticFeedbackEnabled"] as? Bool == false)
        #expect(ctx["watchQuickBookmarkTimeoutSeconds"] as? Int == 10)
        #expect(ctx["loopMode"] as? String == "bookmark")
        #expect(ctx["playbackSpeed"] as? Double == 1.5)
        #expect(ctx["watchPage1"] as? Data == Data([0x01]))
        #expect(ctx["watchPage2"] as? Data == Data([0x02]))
        #expect(ctx["linearBarMode"] as? String == "chapter")
        #expect(ctx["linearBarHidden"] as? Bool == true)
        #expect(ctx["circularRingMode"] as? String == "total")
        #expect(ctx["circularRingHidden"] as? Bool == true)
        #expect(ctx["watchArtworkLayout"] as? String == "compact")
        #expect(ctx["watchBackgroundStyle"] as? String == "solid")
    }

    // MARK: - Thumbnail

    @Test("hasThumbnail is false by default and true when set")
    func thumbnailAvailability() {
        var snap = WatchStateSnapshot()
        snap.hasThumbnail = false
        #expect(WatchStateContextBuilder.build(from: snap)["hasThumbnail"] as? Bool == false)

        snap.hasThumbnail = true
        #expect(WatchStateContextBuilder.build(from: snap)["hasThumbnail"] as? Bool == true)
    }

    // MARK: - Sleep timer

    @Test("sleep timer off state is serialized correctly")
    func sleepTimerOff() {
        var snap = WatchStateSnapshot()
        snap.sleepTimerMode = .off
        snap.sleepTimerRemainingSeconds = 0

        let ctx = WatchStateContextBuilder.build(from: snap)

        #expect(ctx["sleepTimerMode"] as? String == "off")
        #expect(ctx["sleepTimerRemainingSeconds"] as? Int == 0)
    }

    @Test("sleep timer minutes state includes minutes and remaining")
    func sleepTimerMinutes() {
        var snap = WatchStateSnapshot()
        snap.sleepTimerMode = .minutes(15)
        snap.sleepTimerRemainingSeconds = 720

        let ctx = WatchStateContextBuilder.build(from: snap)

        #expect(ctx["sleepTimerMode"] as? String == "minutes")
        #expect(ctx["sleepTimerMinutes"] as? Int == 15)
        #expect(ctx["sleepTimerRemainingSeconds"] as? Int == 720)
    }

    @Test("sleep timer endOfChapter state is serialized correctly")
    func sleepTimerEndOfChapter() {
        var snap = WatchStateSnapshot()
        snap.sleepTimerMode = .endOfChapter
        snap.sleepTimerRemainingSeconds = 42

        let ctx = WatchStateContextBuilder.build(from: snap)

        #expect(ctx["sleepTimerMode"] as? String == "endOfChapter")
        #expect(ctx["sleepTimerRemainingSeconds"] as? Int == 0)
    }

    // MARK: - Word cloud

    @Test("word cloud is JSON-encoded when words are present")
    func wordCloudEncoded() {
        var snap = WatchStateSnapshot()
        snap.wordCloud = [
            WordFrequency(word: "arrakis", count: 15),
            WordFrequency(word: "spice", count: 12),
        ]
        snap.currentChapterIndex = 3

        let ctx = WatchStateContextBuilder.build(from: snap)

        #expect(ctx["wordCloudChapterIndex"] as? Int == 3)
        let json = ctx["wordCloudJSON"] as? String
        #expect(json != nil)
        #expect(json!.contains("arrakis"))
        #expect(json!.contains("spice"))
    }

    @Test("word cloud is omitted when empty")
    func wordCloudEmpty() {
        var snap = WatchStateSnapshot()
        snap.wordCloud = []

        let ctx = WatchStateContextBuilder.build(from: snap)

        #expect(ctx["wordCloudJSON"] == nil)
    }

    @Test("word cloud is truncated to first 10 items")
    func wordCloudTruncatedToFirst10() {
        var snap = WatchStateSnapshot()
        // Caller pre-sorts the cloud; builder takes prefix(10).
        snap.wordCloud = (1...15).map { WordFrequency(word: "word\($0)", count: $0) }

        let ctx = WatchStateContextBuilder.build(from: snap)

        let json = ctx["wordCloudJSON"] as? String
        #expect(json != nil)
        // First 10 items (word1 through word10) should be present.
        #expect(json!.contains("word1"))
        #expect(json!.contains("word10"))
        // Items beyond the first 10 should be excluded.
        #expect(!json!.contains("word11"))
        if let data = json!.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([WordFrequency].self, from: data) {
            #expect(decoded.count == 10)
        }
    }

    // MARK: - Due flashcards

    @Test("due flashcards are JSON-encoded when present")
    func dueFlashcardsEncoded() {
        var snap = WatchStateSnapshot()
        snap.dueFlashcards = [
            WatchFlashcard(id: "card-1", frontText: "What is the spice?", backText: "Melange"),
            WatchFlashcard(id: "card-2", frontText: "Who are the Fremen?", backText: "Desert people"),
        ]

        let ctx = WatchStateContextBuilder.build(from: snap)

        let json = ctx["dueCardsJSON"] as? String
        #expect(json != nil)
        #expect(json!.contains("card-1"))
        #expect(json!.contains("Melange"))
        #expect(json!.contains("Fremen"))
    }

    @Test("due flashcards are omitted when array is empty")
    func dueFlashcardsEmpty() {
        var snap = WatchStateSnapshot()
        snap.dueFlashcards = []

        let ctx = WatchStateContextBuilder.build(from: snap)

        #expect(ctx["dueCardsJSON"] == nil)
    }
}
