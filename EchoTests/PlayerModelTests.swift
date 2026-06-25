// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
struct PlayerModelTests {
    private final class FakeEntitlement: ProEntitlementProviding {
        var isPro: Bool

        init(isPro: Bool = false) {
            self.isPro = isPro
        }
    }

    @Test("PlayerModel initializes with default services")
    func initDefaults() {
        let model = PlayerModel()

        #expect(model.isPlaying == false)
        #expect(model.currentTitle == "No track selected")
        #expect(model.currentPlaybackTime == 0)
    }

    @Test(
        "PlayerModel importEPUB preserves the source EPUB file when imported from the same folder")
    func importEPUBPreservesSourceWhenSameFolder() throws {
        let model = PlayerModel()
        let db = try DatabaseService(inMemory: ())
        model.databaseService = db

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        model.folderURL = tmpDir

        // Create a fake EPUB file inside the folder
        let epubURL = tmpDir.appendingPathComponent("test.epub")
        try Data("fake epub content".utf8).write(to: epubURL)

        // Verify the file exists initially
        #expect(FileManager.default.fileExists(atPath: epubURL.path))

        // Trigger importEPUB from the exact file location
        model.importEPUB(from: epubURL)

        // Verify the file was NOT deleted!
        #expect(FileManager.default.fileExists(atPath: epubURL.path))
    }

    @Test(
        "PlayerModel importEPUB deletes other EPUBs and copies new one when imported from outside folder"
    )
    func importEPUBDeletesOtherEPUBs() async throws {
        let model = PlayerModel()
        let db = try DatabaseService(inMemory: ())
        model.databaseService = db

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        model.folderURL = tmpDir

        // Create an existing epub in the folder (which should be deleted)
        let oldEpubURL = tmpDir.appendingPathComponent("old.epub")
        try Data("old epub content".utf8).write(to: oldEpubURL)

        // Create source epub outside the folder
        let outerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outerDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outerDir) }

        let sourceEpubURL = outerDir.appendingPathComponent("new.epub")
        try Data("new epub content".utf8).write(to: sourceEpubURL)

        // Trigger importEPUB
        model.importEPUB(from: sourceEpubURL)

        // Wait for asynchronous import task to finish
        let destinationURL = tmpDir.appendingPathComponent("new.epub")
        let start = Date()
        while !FileManager.default.fileExists(atPath: destinationURL.path)
            && Date().timeIntervalSince(start) < 1.0
        {
            try await Task.sleep(for: .milliseconds(10))
        }

        // Verify old EPUB is deleted to ensure a single companion document
        #expect(!FileManager.default.fileExists(atPath: oldEpubURL.path))

        // Verify new EPUB is copied into folder
        #expect(FileManager.default.fileExists(atPath: destinationURL.path))

        // Verify source EPUB at original location is NOT deleted
        #expect(FileManager.default.fileExists(atPath: sourceEpubURL.path))
    }

    @Test("hasPreviousChapter / hasNextChapter reflect chapter bounds")
    func chapterNavBoundsHelpers() {
        let model = PlayerModel()

        // No chapters → both false (single-chapter / marker-less book).
        #expect(model.hasPreviousChapter == false)
        #expect(model.hasNextChapter == false)

        // Three chapters, positioned at the first chapter.
        model.state.chapters = [
            Chapter(index: 0, title: "One", startSeconds: 0, endSeconds: 10),
            Chapter(index: 1, title: "Two", startSeconds: 10, endSeconds: 20),
            Chapter(index: 2, title: "Three", startSeconds: 20, endSeconds: 30),
        ]
        model.state.currentChapterIndex = 0
        #expect(model.hasPreviousChapter == false)
        #expect(model.hasNextChapter == true)

        // Middle chapter → both directions available.
        model.state.currentChapterIndex = 1
        #expect(model.hasPreviousChapter == true)
        #expect(model.hasNextChapter == true)

        // Last chapter → only previous.
        model.state.currentChapterIndex = 2
        #expect(model.hasPreviousChapter == true)
        #expect(model.hasNextChapter == false)

        // chapters present but index unresolved (nil) → treated as index 0.
        model.state.currentChapterIndex = nil
        #expect(model.hasPreviousChapter == false)
        #expect(model.hasNextChapter == true)
    }

    @Test("togglePlayPause routes start branch through PlayerModel.play")
    func togglePlayPauseUsesNarrationAwarePlayPath() throws {
        let source = try Self.source(named: "PlayerModel.swift")
        #expect(source.contains("func togglePlayPause()"))
        #expect(source.contains("if isPlaying {\n            pause()\n        } else {\n            play()\n        }"))
        #expect(!source.contains("func togglePlayPause() {\n        playbackController.togglePlayPause()\n    }"))
    }

    @Test("narration books count as playback content before tracks exist")
    func narrationBooksCountAsPlaybackContent() throws {
        let source = try Self.source(named: "PlayerModel+Narration.swift")
        #expect(source.contains("var hasPlaybackContent: Bool"))
        #expect(source.contains("!state.tracks.isEmpty"))
        #expect(source.contains("isNarrationBook && NarrationCapability.supportsOnDeviceNarration"))
    }

    @Test("free users hit narration paywall after first uncached chapter")
    func narrationRenderGateShowsPaywallWhenFreeCapReached() {
        let model = PlayerModel()
        model.state.narrationRenderInFlight = true
        model.state.awaitingNarrationChapter = true
        model.setFreeTierGate(
            FreeTierGate(
                entitlement: FakeEntitlement(),
                narratedChapters: { _ in FreeTierGate.freeNarrationChaptersPerBook }
            )
        )

        #expect(
            !model.allowNarrationRenderOrPresentPaywall(
                audiobookID: "book",
                alreadyRenderedThisChapter: false
            )
        )
        #expect(model.showPaywall)
        #expect(model.paywallContext == .narrationCap)
        #expect(!model.state.narrationRenderInFlight)
        #expect(!model.state.awaitingNarrationChapter)
        #expect(model.narrationPlaybackState.phase == .failed)
    }

    @Test("cached narration chapters stay playable at the free cap")
    func cachedNarrationRenderGateBypassesPaywall() {
        let model = PlayerModel()
        model.setFreeTierGate(
            FreeTierGate(
                entitlement: FakeEntitlement(),
                narratedChapters: { _ in FreeTierGate.freeNarrationChaptersPerBook }
            )
        )

        #expect(
            model.allowNarrationRenderOrPresentPaywall(
                audiobookID: "book",
                alreadyRenderedThisChapter: true
            )
        )
        #expect(!model.showPaywall)
    }

    @Test("narration playback renders and queues segment files")
    func narrationPlaybackUsesSegmentPlan() throws {
        let source = try Self.source(named: "PlayerModel+Narration.swift")
        #expect(source.contains("let segments = NarrationSegmentPlanner.plan(plan)"))
        #expect(source.contains("NarrationSegmentPlanner.resume("))
        #expect(source.contains("NarrationSegmentPlanner.beforeResume("))
        #expect(source.contains("NarrationFileNaming.segmentFileName("))
        #expect(source.contains("try await service.renderSegment("))
        #expect(!source.contains("try await service.renderChapter("))
    }

    private static func source(named fileName: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()

        while directory.path != "/" {
            let candidate =
                directory
                .deletingLastPathComponent()
                .appendingPathComponent("EchoCore/ViewModels")
                .appendingPathComponent(fileName)

            if FileManager.default.fileExists(atPath: candidate.path),
                let content = try? String(contentsOf: candidate, encoding: .utf8)
            {
                return content
            }

            directory.deleteLastPathComponent()
        }

        throw CocoaError(.fileNoSuchFile)
    }
}
