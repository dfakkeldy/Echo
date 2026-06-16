// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Unit tests for the pure chapter-loop / end-of-chapter boundary decision
/// used by the macOS raw-AVPlayer model (MacPlayerModel). The decision logic
/// lives in Shared/ so it is reachable from this test target; MacPlayerModel
/// itself is in the `Echo macOS` target and is exercised structurally (G4).
struct MacChapterLoopDecisionTests {

    private func makeChapters() -> [Chapter] {
        [
            Chapter(index: 0, title: "One", startSeconds: 0, endSeconds: 100),
            Chapter(index: 1, title: "Two", startSeconds: 100, endSeconds: 250),
            Chapter(index: 2, title: "Three", startSeconds: 250, endSeconds: 400),
        ]
    }

    @Test func loopOffNeverActs() {
        let d = MacChapterLoopDecision.evaluate(
            currentTime: 260, chapters: makeChapters(),
            currentChapterIndex: 2, loopMode: .off, isEndOfChapterSleep: false)
        #expect(d == .none)
    }

    @Test func chapterLoopSeeksBackAtBoundary() {
        let d = MacChapterLoopDecision.evaluate(
            currentTime: 250.0, chapters: makeChapters(),
            currentChapterIndex: 1, loopMode: .chapter, isEndOfChapterSleep: false)
        #expect(d == .seek(to: 100.0))
    }

    @Test func chapterLoopDoesNotActMidChapter() {
        let d = MacChapterLoopDecision.evaluate(
            currentTime: 180.0, chapters: makeChapters(),
            currentChapterIndex: 1, loopMode: .chapter, isEndOfChapterSleep: false)
        #expect(d == .none)
    }

    @Test func endOfChapterSleepFiresAtBoundaryWhenNotLooping() {
        let d = MacChapterLoopDecision.evaluate(
            currentTime: 100.0, chapters: makeChapters(),
            currentChapterIndex: 0, loopMode: .off, isEndOfChapterSleep: true)
        #expect(d == .fireSleep)
    }

    @Test func chapterLoopWinsOverSleepWhenBothArmed() {
        let d = MacChapterLoopDecision.evaluate(
            currentTime: 100.0, chapters: makeChapters(),
            currentChapterIndex: 0, loopMode: .chapter, isEndOfChapterSleep: true)
        #expect(d == .seek(to: 0.0))
    }

    @Test func noChaptersNoAction() {
        let d = MacChapterLoopDecision.evaluate(
            currentTime: 50, chapters: [],
            currentChapterIndex: 0, loopMode: .chapter, isEndOfChapterSleep: true)
        #expect(d == .none)
    }

    @Test func outOfRangeIndexIsSafe() {
        let d = MacChapterLoopDecision.evaluate(
            currentTime: 50, chapters: makeChapters(),
            currentChapterIndex: 9, loopMode: .chapter, isEndOfChapterSleep: false)
        #expect(d == .none)
    }
}
