// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import AVFoundation
    import Foundation
    import Testing

    @testable import Echo

    /// Round-trips real m4b chapter markers written by `ChapterMarkerWriter`
    /// (which injects Nero `chpl` + QuickTime `chap` atoms via the
    /// `swift-audio-marker` package) over a copy of an audio file.
    ///
    /// The fixture is generated with Echo's own `AVFoundationAudioWriter` (ALAC in
    /// an `.m4a` container) — the *same* writer the narration export pipeline feeds
    /// into `ChapterMarkerWriter` — so the test exercises the real input shape, not
    /// a hand-rolled container. The test deliberately does **not** `import
    /// AudioMarker`: the package is linked into the Echo app target only, so the
    /// write is driven through `@testable import Echo` and verified from the raw
    /// output bytes + AVFoundation (see the oracle note below).
    ///
    /// ## Verification oracles: raw bytes AND AVFoundation
    ///
    /// `byte`-level assertions verify the chapter atoms we control are embedded and
    /// the container is still valid playable audio. The `chaptersVisibleToAVFoundation`
    /// case additionally drives Apple's own `loadChapterMetadataGroups(_:)` — the
    /// real Books/iOS/macOS reader. That used to come back empty (the upstream text
    /// track was missing the `edts/elst`, `gmhd.text` and `ftab`-bearing `stsd`
    /// AVFoundation requires); Echo's fork of `swift-audio-marker` writes a conformant
    /// chapter track, so AVFoundation now surfaces the chapters.
    @Suite struct ChapterMarkerWriterTests {

        /// `ChapterMarkerWriter` embeds the chapter atoms into a copy of the source
        /// and leaves the result a valid, still-playable audio file.
        @Test func embedsChapterAtomsAndKeepsFilePlayable() async throws {
            let source = try await SilentAudioFixture.makeSilentM4A(seconds: 6)
            defer { try? FileManager.default.removeItem(at: source) }
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4b")
            defer { try? FileManager.default.removeItem(at: output) }

            try await ChapterMarkerWriter().writeChapters(
                [
                    ChapterAtom(startTime: 0, title: "Intro"),
                    ChapterAtom(startTime: 3, title: "Body"),
                ],
                to: source, outputURL: output)

            // (1) The writer produced a real, non-trivial output — not a bare copy.
            //     The source silence contains no "Intro"/"Body" text anywhere; the
            //     output must, because the chapter atoms carry the UTF-8 titles.
            //     (The output is not necessarily *larger* than the source — the
            //     package rebuilds the `moov`/`mdat` layout, which can shrink it —
            //     so the oracle is "titles present", not a byte-count comparison.)
            let sourceBytes = try Data(contentsOf: source)
            let outputBytes = try Data(contentsOf: output)
            #expect(!outputBytes.isEmpty)
            #expect(outputBytes != sourceBytes)
            #expect(outputBytes.range(of: Data("Intro".utf8)) != nil)
            #expect(outputBytes.range(of: Data("Body".utf8)) != nil)
            #expect(sourceBytes.range(of: Data("Intro".utf8)) == nil)

            // (2) The result is still a valid, playable audio asset of the original
            //     length — the atom injection rebuilt the moov without corrupting
            //     the audio track.
            let asset = AVURLAsset(url: output)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            #expect(tracks.count == 1)
            let duration = try await asset.load(.duration)
            #expect(abs(CMTimeGetSeconds(duration) - 6) < 0.25)
        }

        /// AVFoundation's chapter API surfaces the chapter track end to end. This was
        /// historically NOT the case — the upstream `swift-audio-marker` text track
        /// lacked the `edts/elst`, `gmhd.text` and `ftab`-bearing `stsd` that
        /// AVFoundation requires, so `availableChapterLocales` came back empty. Echo
        /// now depends on a fork that writes a conformant chapter track, so Apple's
        /// own reader (Books / iOS / macOS) sees the chapters — asserted here.
        @Test func chaptersVisibleToAVFoundation() async throws {
            let source = try await SilentAudioFixture.makeSilentM4A(seconds: 6)
            defer { try? FileManager.default.removeItem(at: source) }
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4b")
            defer { try? FileManager.default.removeItem(at: output) }

            try await ChapterMarkerWriter().writeChapters(
                [
                    ChapterAtom(startTime: 0, title: "Intro"),
                    ChapterAtom(startTime: 3, title: "Body"),
                ],
                to: source, outputURL: output)

            let asset = AVURLAsset(url: output)
            let locales = try await asset.load(.availableChapterLocales)
            let groups = try await asset.loadChapterMetadataGroups(
                bestMatchingPreferredLanguages: locales.map(\.identifier))
            #expect(groups.count == 2)
        }

        @Test func repairModeReplacesStaleAlbumArtistAndNormalModePreservesIt() async throws {
            let source = try await SilentAudioFixture.makeSilentM4A(seconds: 6)
            let stale = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4b")
            let preserved = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4b")
            let repaired = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4b")
            defer {
                try? FileManager.default.removeItem(at: source)
                try? FileManager.default.removeItem(at: stale)
                try? FileManager.default.removeItem(at: preserved)
                try? FileManager.default.removeItem(at: repaired)
            }

            try await ChapterMarkerWriter().writeChapters(
                [ChapterAtom(startTime: 0, title: "Intro")],
                to: source,
                outputURL: stale,
                metadata: ExportMetadata(
                    title: "Imported Series Album", author: "Stale Album Artist",
                    coverArt: nil))

            try await ChapterMarkerWriter().writeChapters(
                [ChapterAtom(startTime: 0, title: "Intro")],
                to: stale,
                outputURL: preserved,
                metadata: ExportMetadata(title: "Retagged Title", author: "Fresh Author", coverArt: nil))

            #expect(
                try await metadataString(.iTunesMetadataAlbumArtist, at: preserved)
                    == "Stale Album Artist")
            #expect(
                try await metadataString(.iTunesMetadataAlbum, at: preserved)
                    == "Imported Series Album")

            try await ChapterMarkerWriter().writeChapters(
                [ChapterAtom(startTime: 0, title: "Intro")],
                to: stale,
                outputURL: repaired,
                metadata: ExportMetadata(title: "Retagged Title", author: "Fresh Author", coverArt: nil),
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

    }
#endif
