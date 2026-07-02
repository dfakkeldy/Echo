// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct NarrationFileNamingTests {
    @Test func parsesChapterIndexFromFileName() {
        // Format: "{safeID}-ch{N}-{voice}.m4a" — safeID has no '-' (safeToken maps
        // non-alphanumerics to '_'), so "-ch" only marks the chapter separator.
        #expect(NarrationFileNaming.chapterIndex(fromFileName: "book_id-ch0-af_heart.m4a") == 0)
        #expect(NarrationFileNaming.chapterIndex(fromFileName: "x_y-ch12-bf_emma.m4a") == 12)
    }

    @Test func returnsNilForNonNarrationFileName() {
        #expect(NarrationFileNaming.chapterIndex(fromFileName: "cover.jpg") == nil)
        #expect(NarrationFileNaming.chapterIndex(fromFileName: "book-noch-af_heart.m4a") == nil)
    }

    @Test func segmentFileNameRoundTrips() {
        let name = NarrationFileNaming.segmentFileName(
            audiobookID: "file:///b/", chapterIndex: 3, segmentIndex: 2,
            voice: VoiceID("af_heart"))

        #expect(name.contains("-ch3-s2-af_heart-v\(NarrationFileNaming.renderVersion).m4a"))
        let location = NarrationFileNaming.segmentLocation(fromFileName: name)
        #expect(location?.chapterIndex == 3)
        #expect(location?.segmentIndex == 2)
        #expect(NarrationFileNaming.chapterIndex(fromFileName: name) == 3)
    }

    @Test func contentSignatureChangesWithRenderedTextBlockIdentityAndRenderParameters() {
        let spokenBlock = block(id: "b0", text: "Kubernetes ships.")
        let plain = NarrationFileNaming.contentSignature(
            spokenBlocks: [spokenBlock],
            renderedTexts: ["Kubernetes ships."],
            includeLeadOutPad: false)
        let overridden = NarrationFileNaming.contentSignature(
            spokenBlocks: [spokenBlock],
            renderedTexts: ["[Kubernetes](/ku:bərnetis/) ships."],
            includeLeadOutPad: false)
        let differentBlock = NarrationFileNaming.contentSignature(
            spokenBlocks: [block(id: "b1", text: "Kubernetes ships.")],
            renderedTexts: ["Kubernetes ships."],
            includeLeadOutPad: false)
        let padded = NarrationFileNaming.contentSignature(
            spokenBlocks: [spokenBlock],
            renderedTexts: ["Kubernetes ships."],
            includeLeadOutPad: true)
        let fmMode = NarrationFileNaming.contentSignature(
            spokenBlocks: [spokenBlock],
            renderedTexts: ["Kubernetes ships."],
            includeLeadOutPad: false,
            normalizationMode: "fm-auto-v\(FMNormalizer.signatureVersion)")

        #expect(plain.count == 16)
        #expect(plain != overridden)
        #expect(plain != differentBlock)
        #expect(plain != padded)
        #expect(plain != fmMode)
    }

    @Test func contentSignedFileNamesStillRoundTripLocations() {
        let signature = "0123456789abcdef"
        let segment = NarrationFileNaming.segmentFileName(
            audiobookID: "file:///b/",
            chapterIndex: 3,
            segmentIndex: 2,
            voice: VoiceID("af_heart"),
            contentSignature: signature)
        let chapter = NarrationFileNaming.chapterFileName(
            audiobookID: "file:///b/",
            chapterIndex: 3,
            voice: VoiceID("af_heart"),
            contentSignature: signature)

        #expect(
            segment.contains(
                "-ch3-s2-h\(signature)-af_heart-v\(NarrationFileNaming.renderVersion).m4a"))
        #expect(
            chapter.contains(
                "-ch3-h\(signature)-af_heart-v\(NarrationFileNaming.renderVersion).m4a"))
        #expect(NarrationFileNaming.segmentLocation(fromFileName: segment)?.chapterIndex == 3)
        #expect(NarrationFileNaming.segmentLocation(fromFileName: segment)?.segmentIndex == 2)
        #expect(NarrationFileNaming.chapterIndex(fromFileName: chapter) == 3)
    }

    @Test func currentChapterCacheFileNameMatchesSignedLegacyAndPartialChapterFilesOnly() {
        let signed = NarrationFileNaming.chapterFileName(
            audiobookID: "book",
            chapterIndex: 3,
            voice: VoiceID("af_heart"),
            contentSignature: "0123456789abcdef")
        let legacy = NarrationFileNaming.chapterFileName(
            audiobookID: "book",
            chapterIndex: 3,
            voice: VoiceID("af_heart"))
        let segment = NarrationFileNaming.segmentFileName(
            audiobookID: "book",
            chapterIndex: 3,
            segmentIndex: 0,
            voice: VoiceID("af_heart"),
            contentSignature: "0123456789abcdef")

        #expect(
            NarrationFileNaming.isCurrentChapterCacheFileName(
                signed,
                audiobookID: "book",
                chapterIndex: 3,
                voice: VoiceID("af_heart")))
        #expect(
            NarrationFileNaming.isCurrentChapterCacheFileName(
                legacy,
                audiobookID: "book",
                chapterIndex: 3,
                voice: VoiceID("af_heart")))
        #expect(
            NarrationFileNaming.isCurrentChapterCacheFileName(
                "\(signed).partial",
                audiobookID: "book",
                chapterIndex: 3,
                voice: VoiceID("af_heart"),
                includingPartial: true))
        #expect(
            NarrationFileNaming.isCurrentChapterCacheFileName(
                ".book-ch3-h0123456789abcdef-af_heart-v\(NarrationFileNaming.renderVersion)"
                    + ".partial.m4a",
                audiobookID: "book",
                chapterIndex: 3,
                voice: VoiceID("af_heart"),
                includingPartial: true))
        #expect(
            !NarrationFileNaming.isCurrentChapterCacheFileName(
                "\(signed).partial",
                audiobookID: "book",
                chapterIndex: 3,
                voice: VoiceID("af_heart")))
        #expect(
            !NarrationFileNaming.isCurrentChapterCacheFileName(
                segment,
                audiobookID: "book",
                chapterIndex: 3,
                voice: VoiceID("af_heart")))
        #expect(
            !NarrationFileNaming.isCurrentChapterCacheFileName(
                signed,
                audiobookID: "book",
                chapterIndex: 30,
                voice: VoiceID("af_heart")))
    }

    @Test func segmentLocationRejectsNonSegmentNames() {
        #expect(NarrationFileNaming.segmentLocation(fromFileName: "nope.m4a") == nil)
        #expect(
            NarrationFileNaming.segmentLocation(
                fromFileName: "book_id-ch0-af_heart-v\(NarrationFileNaming.renderVersion).m4a")
                == nil)
    }

    private func block(id: String, text: String) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id,
            audiobookID: "book",
            spineHref: "chapter.xhtml",
            spineIndex: 0,
            blockIndex: 0,
            sequenceIndex: 0,
            blockKind: "paragraph",
            text: text,
            htmlContent: nil,
            cardColor: nil,
            chapterThemeColor: nil,
            imagePath: nil,
            chapterIndex: 0,
            isHidden: false,
            hiddenReason: nil,
            isFrontMatter: false,
            wordCount: nil,
            markers: nil,
            textFormats: nil,
            createdAt: nil,
            modifiedAt: nil)
    }
}
