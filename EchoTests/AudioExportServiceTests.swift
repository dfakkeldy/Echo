// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import Echo

@Suite struct AudioExportServiceTests {
    /// Empty input is a clear error, not an empty file.
    @Test func throwsOnNoChapters() async {
        let service = AudioExportService()
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4b")
        await #expect(throws: AudioExportService.ExportError.self) {
            try await service.exportM4B(items: [], outputURL: out)
        }
    }

    #if os(iOS) || os(macOS)
        /// The full `exportM4B(metadata:)` round-trip must preserve BOTH the chapter
        /// atoms AND the book-level title — the chaptered audiobook is the core
        /// feature, so any container rebuild that drops chapters in service of
        /// stamping metadata is a regression.
        ///
        /// ## Why the oracle is byte-level here (and AVFoundation in the sibling test)
        ///
        /// Both are written by `swift-audio-marker` in a single container-preserving
        /// `modify` pass (chapters as Nero `chpl`/QuickTime `chap`; title/artist as
        /// `ilst` `©nam`/`©ART`). This test's oracle is deliberately *low-level*: it
        /// asserts the title/author/chapter strings (and the `mdir`/`aART`/`elst`/
        /// `ftab` marker atoms) are physically present in the output bytes and absent
        /// from the silent source fixtures — proving the atoms reached the file and
        /// were not stripped by a post-chapter container rebuild, independent of any
        /// reader. The *high-level* oracle — that Apple's own AVFoundation reader
        /// surfaces the title, artist and chapters — lives in the companion
        /// `titleAndChaptersVisibleToAVFoundation` test (mirrored by
        /// `ChapterMarkerWriterTests.chaptersVisibleToAVFoundation`). That used to
        /// come back empty (upstream `swift-audio-marker` omitted the `mdir` handler
        /// and wrote a non-conformant chapter track); Echo's fork fixed both, so the
        /// AVFoundation assertions are now enforced rather than disabled.
        ///
        /// REGRESSION GUARD: this previously *failed* because a Phase-2 passthrough
        /// `AVAssetExportSession` re-export (added only to stamp metadata) rebuilt
        /// the MP4 container and silently stripped the chapter atoms — producing an
        /// export with a title but no chapters. The fix writes chapters + metadata
        /// together in the package's in-place rewrite, with nothing rebuilding the
        /// container afterwards.
        @Test func roundTripPreservesChaptersAndTitle() async throws {
            let a = try await SilentAudioFixture.makeSilentM4A(seconds: 1)
            let b = try await SilentAudioFixture.makeSilentM4A(seconds: 1)
            defer {
                try? FileManager.default.removeItem(at: a)
                try? FileManager.default.removeItem(at: b)
            }
            // Distinctive strings that cannot occur in digital silence.
            let items = [
                ExportItem(title: "ChapterAlpha", url: a, timeRange: nil),
                ExportItem(title: "ChapterBravo", url: b, timeRange: nil),
            ]
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4b")
            defer { try? FileManager.default.removeItem(at: out) }
            try await AudioExportService().exportM4B(
                items: items, outputURL: out,
                metadata: ExportMetadata(
                    title: "RoundTripTitle", author: "RoundTripAuthor", coverArt: nil,
                    comment: "Echo narration — 2026-06-23 · ONNX rv6"))

            let outputBytes = try Data(contentsOf: out)
            let sourceBytes = try Data(contentsOf: a)

            // (a) Chapters survive: the chapter atoms carry the UTF-8 titles. The
            //     silent source fixtures contain neither; the final export must
            //     contain both, proving the chapter atoms reached the output and were
            //     not stripped by any post-chapter container rebuild.
            #expect(outputBytes.range(of: Data("ChapterAlpha".utf8)) != nil)
            #expect(outputBytes.range(of: Data("ChapterBravo".utf8)) != nil)
            #expect(sourceBytes.range(of: Data("ChapterAlpha".utf8)) == nil)

            // (b) Title (and author) survive: written into the same `ilst` atoms in
            //     the same pass, so the strings are present in the output bytes and
            //     absent from the source.
            #expect(outputBytes.range(of: Data("RoundTripTitle".utf8)) != nil)
            #expect(outputBytes.range(of: Data("RoundTripAuthor".utf8)) != nil)
            #expect(sourceBytes.range(of: Data("RoundTripTitle".utf8)) == nil)

            // (c) The book metadata is actually READABLE, not just present: the `meta`
            //     box leads with the iTunes handler (`mdir`) or players ignore the
            //     whole `ilst`. The derived album-artist (`aART`) and genre tags are
            //     written too.
            #expect(outputBytes.range(of: Data("mdir".utf8)) != nil)
            #expect(outputBytes.range(of: Data("aART".utf8)) != nil)
            #expect(outputBytes.range(of: Data("Audiobook".utf8)) != nil)

            // (d) The chapter text track is AVFoundation-conformant: it carries an
            //     edit list (`elst`) and an `ftab`-bearing text `stsd`. (Apple's
            //     reader is exercised directly in `titleAndChaptersVisibleToAVFoundation`.)
            #expect(outputBytes.range(of: Data("elst".utf8)) != nil)
            #expect(outputBytes.range(of: Data("ftab".utf8)) != nil)

            // (e) The version stamp lands in the `©cmt` comment atom.
            #expect(
                outputBytes.range(of: Data("Echo narration — 2026-06-23 · ONNX rv6".utf8)) != nil)
        }

        /// The definitive proof: Apple's own AVFoundation reader (the Books / iOS /
        /// macOS engine) surfaces the book title, artist AND the chapters from a real
        /// export. This previously could NOT pass — upstream `swift-audio-marker`
        /// omitted the iTunes `mdir` handler (so `commonMetadata` was empty) and wrote
        /// a non-conformant chapter track (so `availableChapterLocales` was empty).
        /// Echo's fork fixes both, so this is now an enforced, automated guarantee.
        @Test func titleAndChaptersVisibleToAVFoundation() async throws {
            let a = try await SilentAudioFixture.makeSilentM4A(seconds: 1)
            let b = try await SilentAudioFixture.makeSilentM4A(seconds: 1)
            defer {
                try? FileManager.default.removeItem(at: a)
                try? FileManager.default.removeItem(at: b)
            }
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4b")
            defer { try? FileManager.default.removeItem(at: out) }
            try await AudioExportService().exportM4B(
                items: [
                    ExportItem(title: "One", url: a, timeRange: nil),
                    ExportItem(title: "Two", url: b, timeRange: nil),
                ],
                outputURL: out,
                metadata: ExportMetadata(title: "Round Trip", author: "Tester", coverArt: nil))

            let asset = AVURLAsset(url: out)

            // Book-level tags via Apple's common-metadata reader.
            let meta = try await asset.load(.commonMetadata)
            let title = meta.first { $0.commonKey == .commonKeyTitle }
            let artist = meta.first { $0.commonKey == .commonKeyArtist }
            #expect((try? await title?.load(.stringValue)) == "Round Trip")
            #expect((try? await artist?.load(.stringValue)) == "Tester")

            // Chapters via Apple's chapter API — assert the real titles and time
            // ranges, not just the count (a count check passes for anonymous /
            // mis-timed chapters).
            let locales = try await asset.load(.availableChapterLocales)
            #expect(!locales.isEmpty)
            let groups = try await asset.loadChapterMetadataGroups(
                bestMatchingPreferredLanguages: locales.map(\.identifier))
            #expect(groups.count == 2)
            var chapterTitles: [String] = []
            for group in groups {
                let item = group.items.first { $0.commonKey == .commonKeyTitle }
                if let value = try? await item?.load(.stringValue) { chapterTitles.append(value) }
            }
            #expect(chapterTitles == ["One", "Two"])
            // First chapter starts at 0; second starts at ~1s (the first clip's length).
            #expect(abs(groups[0].timeRange.start.seconds - 0) < 0.05)
            #expect(abs(groups[1].timeRange.start.seconds - 1) < 0.2)
        }

        /// The cover image survives the export and is READABLE by Apple's own
        /// metadata reader — the `commonKeyArtwork` cascade `ExportMetadataResolver`
        /// uses to re-source a cover and the path Books / Music / the lock screen use
        /// to show it. The fork writes `covr` inside an `mdir`-led `ilst`, so unlike
        /// the early pre-fork state there is no AVFoundation-blind caveat: Apple
        /// surfaces the artwork. The decoded image is asserted to be the *same*
        /// 240×240 picture, not merely "some bytes", so a truncated or wrong-typed
        /// `covr` (a cover players silently drop) fails the test.
        @Test func coverArtSurvivesAndIsReadableByAVFoundation() async throws {
            let a = try await SilentAudioFixture.makeSilentM4A(seconds: 1)
            defer { try? FileManager.default.removeItem(at: a) }
            let cover = CoverArtFixture.makeJPEG(width: 240, height: 240)
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4b")
            defer { try? FileManager.default.removeItem(at: out) }
            try await AudioExportService().exportM4B(
                items: [ExportItem(title: "One", url: a, timeRange: nil)],
                outputURL: out,
                metadata: ExportMetadata(title: "Cover Book", author: "Tester", coverArt: cover))

            // (a) A `covr` atom landed in the output and the source silence had none.
            let outputBytes = try Data(contentsOf: out)
            #expect(outputBytes.range(of: Data("covr".utf8)) != nil)

            // (b) Apple's reader returns the artwork and it decodes to the original
            //     240×240 image — proving the embedded `covr` is intact and readable.
            let asset = AVURLAsset(url: out)
            let meta = try await asset.load(.commonMetadata)
            let artworkItem = try #require(meta.first { $0.commonKey == .commonKeyArtwork })
            let data = try await #require(artworkItem.load(.dataValue))
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == 240)
            #expect(image.height == 240)
        }
    #endif
}
