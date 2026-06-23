// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct ReaderFeedDisplayBuilderFilterTests {

    // MARK: fixtures

    /// Minimal EPubBlockRecord via the synthesized memberwise init.
    /// Property order matches EPubBlockRecord.swift:8-30 (D2 fix — use full memberwise init).
    private func block(
        id: String,
        chapterIndex: Int?,
        kind: String,
        text: String? = "x",
        imagePath: String? = nil
    ) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id,
            audiobookID: "B",
            spineHref: "spine.xhtml",
            spineIndex: 0,
            blockIndex: 0,
            sequenceIndex: 0,
            blockKind: kind,
            text: text,
            htmlContent: nil,
            cardColor: nil,
            chapterThemeColor: nil,
            imagePath: imagePath,
            chapterIndex: chapterIndex,
            isHidden: false,
            hiddenReason: nil,
            isFrontMatter: false,
            wordCount: nil,
            markers: nil,
            textFormats: nil,
            createdAt: nil,
            modifiedAt: nil
        )
    }

    private func section(key: Int, items: [ReaderCardItem]) -> ReaderCardSection {
        ReaderCardSection(id: "ch\(key)-s0", headingStack: ["H"], items: items)
    }

    /// Two chapters: chapter 0 (audio) with a heading + paragraph + image;
    /// chapter 1 (no audio) with a heading + paragraph.
    private func sampleSections() -> [ReaderCardSection] {
        [
            section(
                key: 0,
                items: [
                    .chapterHeader(title: "Ch1", chapterIndex: 0),
                    .block(block(id: "b0", chapterIndex: 0, kind: "paragraph")),
                    .block(
                        block(
                            id: "b1", chapterIndex: 0, kind: "image", text: nil, imagePath: "p.jpg")
                    ),
                ]),
            section(
                key: 1,
                items: [
                    .chapterHeader(title: "Ch2", chapterIndex: 1),
                    .block(block(id: "b2", chapterIndex: 1, kind: "paragraph")),
                ]),
        ]
    }

    private let hasAudio: [Int: Bool] = [0: true, 1: false]

    private func ids(_ sections: [ReaderCardSection]) -> [String] {
        sections.flatMap { $0.items.map(\.id) }
    }

    @Test func everythingIsIdentity() {
        let out = ReaderFeedDisplayBuilder.applyFilter(
            .everything, to: sampleSections(), chapterHasAudio: hasAudio)
        #expect(ids(out) == ["ch-0", "b-b0", "b-b1", "ch-1", "b-b2"])
    }

    @Test func audioKeepsOnlyAudioChapterGroups() {
        let out = ReaderFeedDisplayBuilder.applyFilter(
            .audio, to: sampleSections(), chapterHasAudio: hasAudio)
        // Chapter 1 (no audio) dropped entirely; chapter 0 fully retained.
        #expect(ids(out) == ["ch-0", "b-b0", "b-b1"])
    }

    @Test func textKeepsOnlyNoAudioChapterGroups() {
        let out = ReaderFeedDisplayBuilder.applyFilter(
            .text, to: sampleSections(), chapterHasAudio: hasAudio)
        #expect(ids(out) == ["ch-1", "b-b2"])
    }

    @Test func picsKeepsHeadersPlusImageBlocksOnly() {
        let out = ReaderFeedDisplayBuilder.applyFilter(
            .pics, to: sampleSections(), chapterHasAudio: hasAudio)
        // Headers always survive (so the TOC structure stays); only image blocks remain.
        // Chapter 1 has no images → header survives but is emptied of blocks, and a
        // group with only a header is dropped (no content to show under Pics).
        #expect(ids(out) == ["ch-0", "b-b1"])
    }

    @Test func picsAndAudioKeepsImagesInAudioChaptersOnly() {
        // Image b1 is in chapter 0 (audio) → kept. No images in chapter 1.
        let out = ReaderFeedDisplayBuilder.applyFilter(
            .picsAndAudio, to: sampleSections(), chapterHasAudio: hasAudio)
        #expect(ids(out) == ["ch-0", "b-b1"])
    }

    @Test func picsAndAudioDropsImageInNonAudioChapter() {
        var sections = sampleSections()
        // Add an image to chapter 1 (no audio); it must NOT survive picsAndAudio.
        sections[1] = section(
            key: 1,
            items: [
                .chapterHeader(title: "Ch2", chapterIndex: 1),
                .block(block(id: "b2", chapterIndex: 1, kind: "paragraph")),
                .block(
                    block(id: "b3", chapterIndex: 1, kind: "image", text: nil, imagePath: "q.jpg")),
            ])
        let out = ReaderFeedDisplayBuilder.applyFilter(
            .picsAndAudio, to: sections, chapterHasAudio: hasAudio)
        #expect(ids(out) == ["ch-0", "b-b1"])
    }

    @Test func bookmarksChipIsPassThroughUntilPhase2() {
        // No bookmark ReaderCardItem case yet → predicate is a no-op; nothing removed.
        let out = ReaderFeedDisplayBuilder.applyFilter(
            .bookmarks, to: sampleSections(), chapterHasAudio: hasAudio)
        #expect(ids(out) == ["ch-0", "b-b0", "b-b1", "ch-1", "b-b2"])
    }

    @Test func emptyInputYieldsEmpty() {
        let out = ReaderFeedDisplayBuilder.applyFilter(.audio, to: [], chapterHasAudio: hasAudio)
        #expect(out.isEmpty)
    }
}
