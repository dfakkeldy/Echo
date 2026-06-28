// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import AVFoundation
#endif
import Foundation
import Testing

@testable import Echo

/// `M4BRetagger` re-stamps an existing m4b's chapter titles from the EPUB headings
/// while keeping the existing chapter *times* — count-tolerant when the EPUB and the
/// rendered m4b disagree on chapter count.
@Suite struct M4BRetaggerTests {

    @Test func keepsTimesAndAppliesNewTitlesInOrder() {
        let atoms = M4BRetagger.chapterAtoms(
            times: [0, 12.5, 30],
            newTitles: ["Introduction", "The Cat Ate It", "Outro"],
            fallback: ["Chapter 1", "Chapter 2", "Chapter 3"])
        #expect(atoms.map(\.startTime) == [0, 12.5, 30])
        #expect(atoms.map(\.title) == ["Introduction", "The Cat Ate It", "Outro"])
    }

    @Test func fallsBackToExistingTitleWhenFewerNewTitles() {
        // m4b has 3 chapters but the EPUB only yielded 2 heading titles: keep all 3
        // times, fall back to the m4b's own title for the unmatched chapter.
        let atoms = M4BRetagger.chapterAtoms(
            times: [0, 10, 20],
            newTitles: ["Intro", "Body"],
            fallback: ["old-1", "old-2", "old-3"])
        #expect(atoms.count == 3)
        #expect(atoms.map(\.title) == ["Intro", "Body", "old-3"])
    }

    @Test func extraNewTitlesAreDropped() {
        let atoms = M4BRetagger.chapterAtoms(
            times: [0, 10], newTitles: ["A", "B", "C", "D"], fallback: [])
        #expect(atoms.map(\.title) == ["A", "B"])
    }

    #if os(iOS) || os(macOS)
        @Test func retagReplacesStaleAlbumArtistWhenAuthorIsProvided() async throws {
            let source = try await SilentAudioFixture.makeSilentM4A(seconds: 6)
            let stale = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4b")
            let repaired = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4b")
            let expandedEPUBDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: expandedEPUBDir, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: source)
                try? FileManager.default.removeItem(at: stale)
                try? FileManager.default.removeItem(at: repaired)
                try? FileManager.default.removeItem(at: expandedEPUBDir)
            }

            try await ChapterMarkerWriter().writeChapters(
                [ChapterAtom(startTime: 0, title: "Intro")],
                to: source,
                outputURL: stale,
                metadata: ExportMetadata(
                    title: "Imported Series Album", author: "Stale Album Artist",
                    coverArt: nil))

            try await M4BRetagger.retag(
                m4b: stale,
                expandedEPUBDir: expandedEPUBDir,
                out: repaired,
                title: "Retagged Title",
                author: "Fresh Author",
                comment: "test retag",
                replaceExistingBookMetadata: true)

            #expect(
                try await metadataString(.iTunesMetadataAlbumArtist, at: repaired)
                    == "Fresh Author")
            #expect(try await metadataString(.iTunesMetadataAlbum, at: repaired) == "Retagged Title")
            #expect(try await metadataString(.iTunesMetadataArtist, at: repaired) == "Fresh Author")
        }

        private func metadataString(_ identifier: AVMetadataIdentifier, at url: URL) async throws
            -> String?
        {
            let asset = AVURLAsset(url: url)
            let metadata = try await asset.load(.metadata)
            let item = metadata.first { $0.identifier?.rawValue == identifier.rawValue }
            return try await item?.load(.stringValue)
        }
    #endif
}
