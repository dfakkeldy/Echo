// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

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

    @Test("context carries the recency stamp the watch uses to drop stale snapshots")
    func contextCarriesStateSeq() {
        var older = WatchStateSnapshot()
        older.contextSeq = 12_345.678
        older.artworkSeq = 12_345.0
        let olderCtx = WatchStateContextBuilder.build(from: older)
        #expect(olderCtx["stateSeq"] as? Double == 12_345.678)
        #expect(olderCtx["artworkSeq"] as? Double == 12_345.0)

        var newer = WatchStateSnapshot()
        newer.contextSeq = 12_346.0
        let newerCtx = WatchStateContextBuilder.build(from: newer)
        #expect((newerCtx["stateSeq"] as? Double ?? 0) > (olderCtx["stateSeq"] as? Double ?? 0))
    }

    @Test("recency sequence survives relaunch and a backward clock adjustment")
    func stateSequenceIsPersistentlyMonotonic() throws {
        let suiteName = "WatchStateSequenceGeneratorTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var generator = WatchStateSequenceGenerator(defaults: defaults)
        let first = generator.next(now: Date(timeIntervalSinceReferenceDate: 500))
        let afterClockRollback = generator.next(now: Date(timeIntervalSinceReferenceDate: 100))

        var relaunchedGenerator = WatchStateSequenceGenerator(defaults: defaults)
        let afterRelaunch = relaunchedGenerator.next(
            now: Date(timeIntervalSinceReferenceDate: 99))

        #expect(afterClockRollback > first)
        #expect(afterRelaunch > afterClockRollback)
    }

    @Test("missing track ID is omitted from context")
    func missingTrackIdOmitted() {
        var snap = WatchStateSnapshot()
        snap.currentTrackId = nil

        let ctx = WatchStateContextBuilder.build(from: snap)

        #expect(ctx["trackId"] == nil)
    }

    // MARK: - Whole-book boundaries + crown volume

    @Test("whole-book boundaries and crown volume state reach the context")
    func boundariesAndCrownVolume() {
        var snap = WatchStateSnapshot()
        snap.bookBoundaryFractions = [0.25, 0.5, 0.75]
        snap.outputGainDB = -3.5
        snap.crownVolumeSensitivity = 0.2

        let ctx = WatchStateContextBuilder.build(from: snap)

        #expect(ctx["bookBoundaryFractions"] as? [Double] == [0.25, 0.5, 0.75])
        #expect(ctx["outputGainDB"] as? Double == -3.5)
        #expect(ctx["crownVolumeSensitivity"] as? Double == 0.2)
    }

    @Test("empty boundaries stay present so the watch clears stale segments")
    func emptyBoundariesExplicit() {
        let ctx = WatchStateContextBuilder.build(from: WatchStateSnapshot())
        #expect((ctx["bookBoundaryFractions"] as? [Double])?.isEmpty == true)
    }

    @Test("boundary payload is capped at the transport limit")
    func boundariesCapped() {
        var snap = WatchStateSnapshot()
        snap.bookBoundaryFractions = (1...100).map { Double($0) / 101.0 }

        let ctx = WatchStateContextBuilder.build(from: snap)

        #expect(
            (ctx["bookBoundaryFractions"] as? [Double])?.count
                == BookProgressSegmentMetrics.maxTransportBoundaries)
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

        #expect(ctx["title"] as? String == "Ch 1")
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

    @Test("total progress uses supplied book-absolute time before track fallback")
    func totalProgressUsesBookAbsoluteTime() {
        var snap = WatchStateSnapshot()
        snap.currentIndex = 1
        snap.trackCount = 3
        snap.progressFraction = 0.25
        snap.currentPlaybackTime = 150
        snap.durationSeconds = 300

        let ctx = WatchStateContextBuilder.build(from: snap)

        #expect(ctx["totalProgressFraction"] as? Double == 0.5)
        #expect(ctx["totalBookDuration"] as? Double == 300)
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

    @Test("artwork accent is always present so neutral artwork clears stale color")
    func artworkAccentIncludesExplicitClearValue() {
        var snap = WatchStateSnapshot()
        snap.artworkAccentColorHex = "#A1B2C3"
        #expect(
            WatchStateContextBuilder.build(from: snap)["artworkAccentColorHex"] as? String
                == "#A1B2C3")

        snap.artworkAccentColorHex = nil
        #expect(
            WatchStateContextBuilder.build(from: snap)["artworkAccentColorHex"] as? String == "")
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
            let decoded = try? JSONDecoder().decode([WordFrequency].self, from: data)
        {
            #expect(decoded.count == 10)
        }
    }

    // MARK: - Due flashcards

    @Test("due flashcards are JSON-encoded when present")
    func dueFlashcardsEncoded() {
        var snap = WatchStateSnapshot()
        snap.dueFlashcards = [
            WatchFlashcard(id: "card-1", frontText: "What is the spice?", backText: "Melange"),
            WatchFlashcard(
                id: "card-2", frontText: "Who are the Fremen?", backText: "Desert people"),
        ]

        let ctx = WatchStateContextBuilder.build(from: snap)

        let json = ctx["dueCardsJSON"] as? String
        #expect(json != nil)
        #expect(json!.contains("card-1"))
        #expect(json!.contains("Melange"))
        #expect(json!.contains("Fremen"))
    }

    @Test("empty due flashcards are JSON-encoded to clear stale watch queues")
    func dueFlashcardsEmpty() throws {
        var snap = WatchStateSnapshot()
        snap.dueFlashcards = []

        let ctx = WatchStateContextBuilder.build(from: snap)
        let json = try #require(ctx["dueCardsJSON"] as? String)
        let data = try #require(json.data(using: .utf8))
        let cards = try JSONDecoder().decode([WatchFlashcard].self, from: data)

        #expect(cards.isEmpty)
    }

    // MARK: - Cover ramp

    @Test("the cover ramp rides the state reply as two short strings")
    func contextCarriesCoverRamp() {
        var snap = WatchStateSnapshot()
        snap.artworkAccentColorHex = "#B98A2E"
        snap.coverRampTopHex = "#3A2A12"
        snap.coverRampBottomHex = "#2C1F0D"

        let ctx = WatchStateContextBuilder.build(from: snap)

        #expect(ctx["coverRampTopHex"] as? String == "#3A2A12")
        #expect(ctx["coverRampBottomHex"] as? String == "#2C1F0D")
    }

    @Test("a neutral cover clears the ramp explicitly rather than omitting it")
    func neutralCoverClearsRamp() {
        // Same contract as the accent: omitting the keys would leave the
        // previous book's room cached on the watch behind a neutral cover.
        let ctx = WatchStateContextBuilder.build(from: WatchStateSnapshot())

        #expect(ctx["coverRampTopHex"] as? String == "")
        #expect(ctx["coverRampBottomHex"] as? String == "")
    }

    @Test("the ramp keeps watch payloads bounded")
    func rampIsCheapOnTheWire() {
        var snap = WatchStateSnapshot()
        snap.coverRampTopHex = "#3A2A12"
        snap.coverRampBottomHex = "#2C1F0D"

        let ctx = WatchStateContextBuilder.build(from: snap)
        let ramp = [ctx["coverRampTopHex"], ctx["coverRampBottomHex"]].compactMap { $0 as? String }

        // PR #521 bounded these replies; the ramp must stay hex strings and
        // never grow into image data.
        #expect(ramp.count == 2)
        #expect(ramp.allSatisfy { $0.count <= 7 })
    }
}
