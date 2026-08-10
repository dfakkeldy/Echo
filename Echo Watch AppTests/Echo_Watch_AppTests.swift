// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Echo_Watch_AppTests.swift
//  Echo Watch AppTests
//
//  Created by Dan Fakkeldy on 2026-05-02.
//

import Foundation
import Testing
import UIKit

@testable import Echo_Watch_App

@Suite(.serialized)
struct Echo_Watch_AppTests {

    @Test func watchActionCommandsMatchPhoneCommandNames() {
        #expect(WatchAction.playPause.command == "toggle")
        #expect(WatchAction.skipForward.command == "skipForward")
        #expect(WatchAction.skipBackward.command == "skipBackward")
        #expect(WatchAction.nextTrack.command == "next")
        #expect(WatchAction.previousTrack.command == "previous")
        #expect(WatchAction.loopMode.command == "cycleLoopMode")
        #expect(WatchAction.speed.command == "cycleSpeed")
        #expect(WatchAction.sleepTimer.command == "toggleSleepTimer")
        #expect(WatchAction.bookmark.command == "addBookmark")
        #expect(WatchAction.pomodoro.command == "pomodoro")
        #expect(WatchAction.empty.command == "")
    }

    @Test func watchActionsRoundtripJSON() throws {
        let original: [WatchAction] = [.skipBackward, .playPause, .empty, .empty, .empty]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([WatchAction].self, from: data)

        #expect(decoded == original)
    }

    @Test func watchActionsMigrationFromOldStringFormat() throws {
        let oldString = "skipBackward,nope,playPause"

        // Simulate the migration path: parse old comma-separated string
        let parsed = oldString.split(separator: ",").compactMap {
            WatchAction(rawValue: String($0))
        }
        var padded = Array(parsed.prefix(5))
        while padded.count < 5 { padded.append(.empty) }

        // Unknown actions (like "nope") are dropped
        #expect(padded == [.skipBackward, .playPause, .empty, .empty, .empty])

        // Verify the result roundtrips through JSON
        let data = try JSONEncoder().encode(padded)
        let decoded = try JSONDecoder().decode([WatchAction].self, from: data)
        #expect(decoded == padded)
    }

    @Test func wakeRefreshPolicyAllowsInitialRefreshAndThrottlesDuplicates() {
        var policy = WatchWakeRefreshPolicy(minimumInterval: 1.0)
        let start = Date(timeIntervalSinceReferenceDate: 100)
        let firstRefresh = policy.shouldRefresh(now: start)
        let duplicateRefresh = policy.shouldRefresh(now: start.addingTimeInterval(0.5))
        let laterRefresh = policy.shouldRefresh(now: start.addingTimeInterval(1.0))

        #expect(firstRefresh)
        #expect(!duplicateRefresh)
        #expect(laterRefresh)
    }

    @Test func wakeRefreshPolicyDoesNotThrottleUntilRefreshIsRecorded() {
        var policy = WatchWakeRefreshPolicy(minimumInterval: 1.0)
        let start = Date(timeIntervalSinceReferenceDate: 100)

        #expect(policy.canRefresh(now: start))
        #expect(policy.canRefresh(now: start.addingTimeInterval(0.5)))

        policy.recordRefresh(now: start.addingTimeInterval(0.5))

        #expect(!policy.canRefresh(now: start.addingTimeInterval(1.0)))
        #expect(policy.canRefresh(now: start.addingTimeInterval(1.5)))
    }

    @MainActor
    @Test func receivedApplicationContextUpdatesWatchState() throws {
        let (defaults, suiteName) = try Self.testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = WatchViewModel(defaults: defaults)
        let applied = viewModel.applyReceivedApplicationContext([
            "stateSeq": 1.0,
            "title": "Updated on iPhone",
            "currentTime": 42.0,
            "totalProgressFraction": 0.25,
            "progressFraction": 0.5,
        ])

        #expect(applied)
        #expect(viewModel.title == "Updated on iPhone")
        #expect(viewModel.currentTime == 42.0)
        #expect(viewModel.totalProgressFraction == 0.25)
        #expect(viewModel.progressFraction == 0.5)
    }

    @MainActor
    @Test func foregroundResumeRestartsProgressFromPersistedPlayingState() async throws {
        let (defaults, suiteName) = try Self.testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "isPlaying")
        defaults.set(120.0, forKey: "currentTime")
        defaults.set(0.5, forKey: "progressFraction")
        defaults.set(240.0, forKey: "chapterDuration")
        defaults.set(1_200.0, forKey: "totalBookDuration")

        let viewModel = WatchViewModel(defaults: defaults)
        defer {
            viewModel.isPlaying = false
            viewModel.appWillEnterForeground()
        }
        let initialTime = viewModel.currentTime
        let initialProgress = viewModel.progressFraction

        viewModel.appWillEnterForeground()
        try await Task.sleep(for: .milliseconds(650))

        #expect(viewModel.currentTime > initialTime)
        #expect(viewModel.progressFraction > initialProgress)
    }

    @Test func snapshotRecencyRejectsOlderEqualAndLegacyFullState() {
        var policy = WatchStateRecencyPolicy()

        let acceptedFirst = policy.shouldApply(
            ["stateSeq": 10.0, "artworkSeq": 9.0, "isPlaying": false],
            source: .applicationContext)
        let acceptedDuplicate = policy.shouldApply(
            ["stateSeq": 10.0, "isPlaying": true], source: .liveMessage)
        let acceptedOlder = policy.shouldApply(
            ["stateSeq": 9.0, "isPlaying": true], source: .applicationContext)
        let acceptedLegacyState = policy.shouldApply(
            [
                "isPlaying": true, "title": "Queued old state",
            ], source: .queuedUserInfo)
        let acceptedThumbnail = policy.shouldApply(
            [
                "artworkSeq": 9.0,
                "artworkKey": "cover",
                "thumbnailData": Data([0x01]),
            ], source: .queuedUserInfo)
        let acceptedNewer = policy.shouldApply(
            ["stateSeq": 11.0, "isPlaying": true], source: .liveMessage)

        #expect(acceptedFirst)
        #expect(!acceptedDuplicate)
        #expect(!acceptedOlder)
        #expect(!acceptedLegacyState)
        #expect(acceptedThumbnail)
        #expect(acceptedNewer)
    }

    @Test func staleQueuedThumbnailCannotRestoreArtworkAfterNewerClear() {
        var policy = WatchStateRecencyPolicy()

        let acceptedInitialState = policy.shouldApply(
            ["stateSeq": 20.0, "artworkSeq": 19.0, "hasThumbnail": true],
            source: .applicationContext)
        let acceptedInitialThumbnail = policy.shouldApply(
            [
                "artworkSeq": 19.0,
                "artworkKey": "track#base",
                "thumbnailData": Data([0x01]),
            ], source: .queuedUserInfo)
        let acceptedClear = policy.shouldApply(
            ["stateSeq": 22.0, "artworkSeq": 21.0, "hasThumbnail": false],
            source: .applicationContext)
        let acceptedStaleThumbnail = policy.shouldApply(
            [
                "artworkSeq": 19.0,
                "artworkKey": "track#base",
                "thumbnailData": Data([0x01]),
            ], source: .queuedUserInfo)

        #expect(acceptedInitialState)
        #expect(acceptedInitialThumbnail)
        #expect(acceptedClear)
        #expect(!acceptedStaleThumbnail)
    }

    @Test func thumbnailAndCompleteSnapshotsShareOneOrderingBoundary() {
        var policy = WatchStateRecencyPolicy(lastAppliedSequence: 30.0)

        let acceptedThumbnail = policy.shouldApply(
            [
                "artworkSeq": 32.0,
                "artworkKey": "track#base",
                "thumbnailData": Data([0x02]),
            ], source: .queuedUserInfo)
        let acceptedOlderFullState = policy.shouldApply(
            ["stateSeq": 31.0, "isPlaying": true], source: .liveMessage)
        let acceptedMatchingFullState = policy.shouldApply(
            ["stateSeq": 33.0, "artworkSeq": 32.0, "isPlaying": false],
            source: .applicationContext)

        #expect(acceptedThumbnail)
        #expect(!acceptedOlderFullState)
        #expect(acceptedMatchingFullState)
    }

    @Test func explicitThumbnailClearRequestsImmediateWidgetReload() {
        #expect(
            WatchWidgetReloadPolicy.shouldReload(
                state: ["hasThumbnail": false],
                currentIsPlaying: false,
                currentTrackId: "same-track",
                currentAccentHex: nil,
                currentRampTopHex: nil,
                hasCachedThumbnail: true))
        #expect(
            !WatchWidgetReloadPolicy.shouldReload(
                state: ["hasThumbnail": false],
                currentIsPlaying: false,
                currentTrackId: "same-track",
                currentAccentHex: nil,
                currentRampTopHex: nil,
                hasCachedThumbnail: false))
    }

    @Test func sameTrackNeutralArtworkClearsPersistedCoverRamp() throws {
        let (defaults, suiteName) = try Self.testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = WatchViewModel(defaults: defaults)

        #expect(
            viewModel.applyReceivedApplicationContext([
                "stateSeq": 30.0,
                "trackId": "same-track",
                "coverRampTopHex": "#3A2A12",
                "coverRampBottomHex": "#2C1F0D",
            ]))
        #expect(viewModel.coverRampTopHex == "#3A2A12")
        #expect(viewModel.coverRampBottomHex == "#2C1F0D")
        #expect(viewModel.coverRampGradient != nil)

        #expect(
            viewModel.applyReceivedApplicationContext([
                "stateSeq": 31.0,
                "trackId": "same-track",
                "coverRampTopHex": "",
                "coverRampBottomHex": "",
            ]))
        #expect(viewModel.coverRampTopHex == nil)
        #expect(defaults.object(forKey: "coverRampTopHex") == nil)
        #expect(defaults.object(forKey: "coverRampBottomHex") == nil)
        // With either end gone the watch keeps flat black rather than drawing
        // half a ramp.
        #expect(viewModel.coverRampGradient == nil)
    }

    @Test func coverRampChangeAloneRequestsImmediateWidgetReload() {
        // A promoted accent is seeded from a different candidate than the room,
        // so displayed bookmark artwork can change the ramp while the accent
        // and the track stay put. Without its own clause that complication
        // would show the previous book's room until the next poll.
        #expect(
            WatchWidgetReloadPolicy.shouldReload(
                state: ["coverRampTopHex": "#3A2A12"],
                currentIsPlaying: false,
                currentTrackId: "same-track",
                currentAccentHex: "#B98A2E",
                currentRampTopHex: "#123456",
                hasCachedThumbnail: false))
        #expect(
            !WatchWidgetReloadPolicy.shouldReload(
                state: ["coverRampTopHex": "#3A2A12"],
                currentIsPlaying: false,
                currentTrackId: "same-track",
                currentAccentHex: "#B98A2E",
                currentRampTopHex: "#3A2A12",
                hasCachedThumbnail: false))
    }

    @Test func queuedLegacyFullStateIsRejectedBeforeAnyStampedSnapshot() {
        var policy = WatchStateRecencyPolicy()

        let acceptedQueuedState = policy.shouldApply(
            [
                "isPlaying": true,
                "title": "Old queued state",
            ], source: .queuedUserInfo)
        let acceptedLegacyContext = policy.shouldApply(
            [
                "isPlaying": false,
                "title": "Current legacy state",
            ], source: .applicationContext)

        #expect(!acceptedQueuedState)
        #expect(acceptedLegacyContext)
    }

    @MainActor
    @Test func queuedUserInfoCannotRestickPlayingStateBeforeFirstSnapshot() throws {
        let (defaults, suiteName) = try Self.testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = WatchViewModel(defaults: defaults)

        #expect(
            !viewModel.applyReceivedUserInfo([
                "isPlaying": true,
                "title": "Old queued state",
            ]))

        #expect(!viewModel.isPlaying)
        #expect(viewModel.title != "Old queued state")
    }

    @MainActor
    @Test func olderSnapshotCannotRestickPlayingState() throws {
        let (defaults, suiteName) = try Self.testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = WatchViewModel(defaults: defaults)

        #expect(
            viewModel.applyReceivedApplicationContext([
                "stateSeq": 20.0, "isPlaying": false, "title": "Paused",
            ]))
        #expect(
            !viewModel.applyReceivedApplicationContext([
                "stateSeq": 19.0, "isPlaying": true, "title": "Stale playing",
            ]))

        #expect(!viewModel.isPlaying)
        #expect(viewModel.title == "Paused")
    }

    @MainActor
    @Test func sameTrackNeutralArtworkClearsPersistedAccent() throws {
        let (defaults, suiteName) = try Self.testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = WatchViewModel(defaults: defaults)

        #expect(
            viewModel.applyReceivedApplicationContext([
                "stateSeq": 30.0,
                "trackId": "same-track",
                "artworkAccentColorHex": "#A1B2C3",
            ]))
        #expect(viewModel.artworkAccentColorHex == "#A1B2C3")

        #expect(
            viewModel.applyReceivedApplicationContext([
                "stateSeq": 31.0,
                "trackId": "same-track",
                "artworkAccentColorHex": "",
            ]))
        #expect(viewModel.artworkAccentColorHex == nil)
        #expect(defaults.object(forKey: "artworkAccentColorHex") == nil)
    }

    @MainActor
    @Test func explicitThumbnailAbsenceClearsSameTrackArtwork() throws {
        let (defaults, suiteName) = try Self.testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = WatchViewModel(defaults: defaults)
        let thumbnailData = try #require(UIImage(systemName: "book")?.pngData())

        #expect(
            viewModel.applyReceivedApplicationContext([
                "stateSeq": 39.0,
                "artworkSeq": 38.0,
                "trackId": "same-track",
                "hasThumbnail": true,
            ]))
        #expect(
            viewModel.applyReceivedUserInfo([
                "artworkSeq": 38.0,
                "artworkKey": "same-track#base",
                "thumbnailData": thumbnailData,
            ]))
        #expect(viewModel.thumbnailImage != nil)

        #expect(
            viewModel.applyReceivedApplicationContext([
                "stateSeq": 41.0,
                "artworkSeq": 40.0,
                "trackId": "same-track",
                "hasThumbnail": false,
            ]))

        #expect(viewModel.thumbnailImage == nil)
        #expect(defaults.object(forKey: "thumbnailData") == nil)

        #expect(
            !viewModel.applyReceivedUserInfo([
                "artworkSeq": 38.0,
                "artworkKey": "same-track#base",
                "thumbnailData": thumbnailData,
            ]))
        #expect(viewModel.thumbnailImage == nil)
        #expect(defaults.object(forKey: "thumbnailData") == nil)
    }

    @MainActor
    @Test func artworkOrderingPersistsAcrossWatchRelaunch() throws {
        let (defaults, suiteName) = try Self.testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstViewModel = WatchViewModel(defaults: defaults)
        #expect(
            firstViewModel.applyReceivedApplicationContext([
                "stateSeq": 51.0,
                "artworkSeq": 50.0,
                "hasThumbnail": false,
            ]))
        #expect(
            defaults.double(forKey: WatchStateRecencyPolicy.persistedArtworkSequenceKey) == 50)

        let relaunchedViewModel = WatchViewModel(defaults: defaults)
        #expect(
            !relaunchedViewModel.applyReceivedUserInfo([
                "artworkSeq": 49.0,
                "artworkKey": "stale#base",
                "thumbnailData": Data([0x01]),
            ]))
    }

    @Test func newBookmarkVoiceMemoButtonIsDoubleTapPrimaryAction() throws {
        let source = try Self.source(named: "PlayerPage.swift")
        let newBookmarkView = try Self.slice(
            of: source,
            after: "struct NewBookmarkView: View",
            until: "struct MarqueeText: View"
        )

        #expect(
            newBookmarkView.contains(
                "recorder.isRecording ? saveVoiceMemo() : startVoiceBookmark()"))
        #expect(newBookmarkView.contains(".handGestureShortcut(.primaryAction)"))
    }

    private static func source(named fileName: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidate =
            root
            .appendingPathComponent("Echo Watch App")
            .appendingPathComponent("Views")
            .appendingPathComponent(fileName)
        return try String(contentsOf: candidate, encoding: .utf8)
    }

    private static func testDefaults() throws -> (UserDefaults, String) {
        let suiteName = "EchoWatchAppTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private static func slice(of source: String, after start: String, until end: String) throws
        -> String
    {
        let startRange = try #require(source.range(of: start))
        let endRange = try #require(source[startRange.upperBound...].range(of: end))
        return String(source[startRange.upperBound..<endRange.lowerBound])
    }

}
