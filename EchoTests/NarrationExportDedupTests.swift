// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// §5.12 — the narration exporter globbed every `<token>-ch*.m4a` regardless of
/// voice or `renderVersion`, so a book re-rendered after a voice change or a
/// version bump left two files for the same chapter index and exported both —
/// concatenating the chapter twice and corrupting chapter timing. These pin the
/// one-file-per-chapter selection (current version + the DB-recorded voice).
@Suite struct NarrationExportDedupTests {

    private let audiobookID = "book_id"

    private func file(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp").appendingPathComponent(name)
    }

    /// The canonical (current render version) name for a chapter+voice.
    private func current(_ chapter: Int, _ voice: String) -> String {
        NarrationFileNaming.chapterFileName(
            audiobookID: audiobookID, chapterIndex: chapter, voice: VoiceID(voice))
    }

    /// An older-render-version name for the same chapter+voice.
    private func older(_ chapter: Int, _ voice: String) -> String {
        "book_id-ch\(chapter)-\(voice)-v\(NarrationFileNaming.renderVersion - 1).m4a"
    }

    private func segment(_ chapter: Int, _ segment: Int, _ voice: String) -> String {
        NarrationFileNaming.segmentFileName(
            audiobookID: audiobookID,
            chapterIndex: chapter,
            segmentIndex: segment,
            voice: VoiceID(voice))
    }

    @Test func keepsOnlyCurrentVersionWhenChapterReRendered() {
        let files = [file(older(0, "af_heart")), file(current(0, "af_heart"))]
        let result = NarrationCacheSource.currentVersionFiles(
            files: files, audiobookID: audiobookID, voiceByChapterIndex: [0: VoiceID("af_heart")])
        #expect(result.map(\.lastPathComponent) == [current(0, "af_heart")])
    }

    @Test func keepsDatabaseVoiceWhenTwoVoicesPresentForOneChapter() {
        let files = [file(current(0, "af_bella")), file(current(0, "af_heart"))]
        let result = NarrationCacheSource.currentVersionFiles(
            files: files, audiobookID: audiobookID, voiceByChapterIndex: [0: VoiceID("af_heart")])
        #expect(result.map(\.lastPathComponent) == [current(0, "af_heart")])
    }

    /// A chapter present only at an older version (not yet re-rendered) is still
    /// exported — the dedup must not drop it to an empty export.
    @Test func keepsStaleFileWhenNoCurrentVersionExists() {
        let stale = older(0, "af_heart")
        let result = NarrationCacheSource.currentVersionFiles(
            files: [file(stale)], audiobookID: audiobookID,
            voiceByChapterIndex: [0: VoiceID("af_heart")])
        #expect(result.map(\.lastPathComponent) == [stale])
    }

    @Test func returnsExactlyOneFilePerChapterAcrossChapters() {
        let files = [
            file(older(0, "af_heart")), file(current(0, "af_heart")), file(current(1, "af_heart")),
        ]
        let result = Set(
            NarrationCacheSource.currentVersionFiles(
                files: files, audiobookID: audiobookID,
                voiceByChapterIndex: [0: VoiceID("af_heart"), 1: VoiceID("af_heart")]
            ).map(\.lastPathComponent))
        #expect(result == [current(0, "af_heart"), current(1, "af_heart")])
    }

    @Test func keepsSegmentFilesWhenSegmentExportIsExplicitlySupported() {
        let files = [
            file(segment(0, 0, "af_heart")),
            file(segment(0, 1, "af_heart")),
            file(current(1, "af_heart")),
        ]
        let result = NarrationCacheSource.currentVersionFiles(
            files: files,
            audiobookID: audiobookID,
            voiceByChapterIndex: [0: VoiceID("af_heart"), 1: VoiceID("af_heart")]
        ).map(\.lastPathComponent)

        #expect(result == [
            segment(0, 0, "af_heart"),
            segment(0, 1, "af_heart"),
            current(1, "af_heart"),
        ])
    }

    @Test func currentVersionFilesKeepsChapterFileOverSegmentsForSameChapter() {
        let files = [
            file(current(0, "af_heart")),
            file(segment(0, 1, "af_heart")),
            file(segment(0, 0, "af_heart")),
        ]
        let result = NarrationCacheSource.currentVersionFiles(
            files: files,
            audiobookID: audiobookID,
            voiceByChapterIndex: [0: VoiceID("af_heart")]
        ).map(\.lastPathComponent)

        #expect(result == [current(0, "af_heart")])
    }

    @Test func orderedItemsCoalescesSegmentMarkersByChapter() {
        let items = NarrationCacheSource.orderedItems(
            files: [
                file(segment(0, 1, "af_heart")),
                file(segment(1, 0, "af_heart")),
                file(segment(0, 0, "af_heart")),
            ],
            titlesByChapterIndex: [0: "Opening", 1: "Next"])

        #expect(items.map(\.url.lastPathComponent) == [
            segment(0, 0, "af_heart"),
            segment(0, 1, "af_heart"),
            segment(1, 0, "af_heart"),
        ])
        #expect(items.map(\.title) == ["Opening", "Opening", "Next"])
        #expect(items.map(\.emitsChapterMarker) == [true, false, true])
    }

    @Test func orderedItemsKeepsOneMarkerPerChapterWhenChapterAndSegmentFilesMix() {
        let items = NarrationCacheSource.orderedItems(
            files: [
                file(current(2, "af_heart")),
                file(segment(0, 1, "af_heart")),
                file(segment(0, 0, "af_heart")),
            ],
            titlesByChapterIndex: [0: "Opening", 2: "Finale"])

        #expect(items.map(\.url.lastPathComponent) == [
            segment(0, 0, "af_heart"),
            segment(0, 1, "af_heart"),
            current(2, "af_heart"),
        ])
        #expect(items.map(\.emitsChapterMarker) == [true, false, true])
    }
}
