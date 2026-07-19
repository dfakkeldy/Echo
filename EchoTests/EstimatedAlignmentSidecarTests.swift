// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

private final class EstimatedSidecarFixtureBundleLocator {}

@Suite struct EstimatedAlignmentSidecarTests {
    @Test func buildsEstimatedAnchorsByWordWeightInsideChapterTimings() throws {
        let blocks = [
            block(spine: 0, index: 0, sequence: 0, words: 1, text: "Intro"),
            block(spine: 0, index: 1, sequence: 1, words: 3, text: "one two three"),
            block(spine: 1, index: 0, sequence: 2, words: 2, text: "next chapter"),
        ]
        let chapters = [
            EstimatedAlignmentSidecar.ChapterTiming(index: 0, start: 0, end: 40),
            EstimatedAlignmentSidecar.ChapterTiming(index: 1, start: 40, end: 100),
        ]

        let anchors = try EstimatedAlignmentSidecar.build(
            blocks: blocks,
            chapterTimings: chapters
        )

        #expect(anchors.map(\.blockId) == ["s0-b0", "s0-b1", "s1-b0"])
        #expect(anchors.map(\.timestamp) == [0, 10, 40])
        #expect(anchors.allSatisfy { $0.confidence == 0.5 })
        #expect(anchors.allSatisfy { $0.sourceBlockIdentity != nil })
    }

    @Test func buildSkipsHiddenImageAndEmptyTextBlocks() throws {
        let blocks = [
            block(spine: 0, index: 0, sequence: 0, kind: .image, words: 1, text: nil),
            block(spine: 0, index: 1, sequence: 1, words: 1, text: "   "),
            block(spine: 0, index: 2, sequence: 2, words: 2, text: "spoken block"),
            block(spine: 0, index: 3, sequence: 3, words: 2, text: "hidden", isHidden: true),
        ]
        let chapters = [
            EstimatedAlignmentSidecar.ChapterTiming(index: 0, start: 5, end: 25)
        ]

        let anchors = try EstimatedAlignmentSidecar.build(
            blocks: blocks,
            chapterTimings: chapters
        )

        #expect(anchors.map(\.blockId) == ["s0-b2"])
        #expect(anchors.first?.timestamp == 5)
    }

    @Test func verifyAcceptsResolvableMonotonicSidecarWithChapterCoverage() throws {
        let blocks = [
            block(spine: 0, index: 0, sequence: 0, words: 1, text: "A"),
            block(spine: 1, index: 0, sequence: 1, words: 1, text: "B"),
        ]
        let chapters = [
            EstimatedAlignmentSidecar.ChapterTiming(index: 0, start: 0, end: 10),
            EstimatedAlignmentSidecar.ChapterTiming(index: 1, start: 10, end: 20),
        ]
        let anchors = [
            AlignmentSidecar.Anchor(blockId: "s0-b0", timestamp: 0, confidence: 0.5),
            AlignmentSidecar.Anchor(blockId: "s1-b0", timestamp: 10, confidence: 0.5),
        ]

        let report = try AlignmentSidecarVerifier.verify(
            anchors: anchors,
            blocks: blocks,
            chapterTimings: chapters,
            audioDuration: 20
        )

        #expect(report.anchorCount == 2)
        #expect(report.chapterCount == 2)
    }

    @Test func verifyRejectsMismatchedSourceIdentity() {
        let source = block(spine: 0, index: 0, sequence: 0, words: 1, text: "Current")
        let anchors = [
            AlignmentSidecar.Anchor(
                blockId: "s0-b0",
                timestamp: 0,
                confidence: 1,
                sourceBlockIdentity: "identity-from-a-different-source"
            )
        ]

        #expect(throws: AlignmentSidecarVerifier.VerificationError.self) {
            _ = try AlignmentSidecarVerifier.verify(
                anchors: anchors,
                blocks: [source],
                chapterTimings: [.init(index: 0, start: 0, end: 10)],
                audioDuration: 10
            )
        }
    }

    @Test func verifyRejectsLegacySidecarForCodeBearingSource() {
        let code = block(
            spine: 0,
            index: 0,
            sequence: 0,
            kind: .code,
            words: 3,
            text: "let value = 42"
        )

        #expect(throws: AlignmentSidecarVerifier.VerificationError.self) {
            _ = try AlignmentSidecarVerifier.verify(
                anchors: [
                    AlignmentSidecar.Anchor(
                        blockId: "s0-b0", timestamp: 0, confidence: 1)
                ],
                blocks: [code],
                chapterTimings: [.init(index: 0, start: 0, end: 10)],
                audioDuration: 10
            )
        }
    }

    @Test func verifyAcceptsCueOnlyCodeAnchorFromNativeNarration() throws {
        var code = block(
            spine: 0,
            index: 1,
            sequence: 1,
            kind: .code,
            words: 3,
            text: "let value = 42"
        )
        code.narrationText = "Example value assignment."
        code.codeLanguage = "swift"
        let blocks = [
            block(spine: 0, index: 0, sequence: 0, words: 1, text: "Intro"),
            code,
        ]
        let chapters = [
            EstimatedAlignmentSidecar.ChapterTiming(index: 0, start: 0, end: 10)
        ]
        let anchors = [
            AlignmentSidecar.Anchor(
                blockId: "s0-b0",
                timestamp: 0,
                confidence: 1,
                sourceBlockIdentity: AlignmentSidecar.sourceIdentity(for: blocks[0])
            ),
            AlignmentSidecar.Anchor(
                blockId: "s0-b1",
                timestamp: 4,
                confidence: 1,
                sourceBlockIdentity: AlignmentSidecar.sourceIdentity(for: code)
            ),
        ]

        let report = try AlignmentSidecarVerifier.verify(
            anchors: anchors,
            blocks: blocks,
            chapterTimings: chapters,
            audioDuration: 10
        )

        #expect(report.anchorCount == 2)
        #expect(report.anchorsWithWords == 0)
    }

    @Test func verifyAcceptsCodeWordsMatchingCueTokenCountInsteadOfRawCode() throws {
        var code = block(
            spine: 0,
            index: 0,
            sequence: 0,
            kind: .code,
            words: 6,
            text: "let value = answer + 42"
        )
        code.narrationText = "Example value assignment."
        let anchors = [
            AlignmentSidecar.Anchor(
                blockId: "s0-b0",
                timestamp: 1,
                confidence: 1,
                words: [
                    AlignmentSidecar.Anchor.Word(word: "Example", start: 1, end: 1.2),
                    AlignmentSidecar.Anchor.Word(word: "value", start: 1.2, end: 1.4),
                    AlignmentSidecar.Anchor.Word(word: "assignment", start: 1.4, end: 1.8),
                ],
                sourceBlockIdentity: AlignmentSidecar.sourceIdentity(for: code)
            )
        ]

        let report = try AlignmentSidecarVerifier.verify(
            anchors: anchors,
            blocks: [code],
            chapterTimings: [.init(index: 0, start: 0, end: 10)],
            audioDuration: 10)

        #expect(report.anchorsWithWords == 1)
    }

    @Test func verifyRejectsCodeWordsMatchingRawCodeInsteadOfCueTokenCount() {
        var code = block(
            spine: 0,
            index: 0,
            sequence: 0,
            kind: .code,
            words: 6,
            text: "let value = answer + 42"
        )
        code.narrationText = "Example value assignment."
        let anchors = [
            AlignmentSidecar.Anchor(
                blockId: "s0-b0",
                timestamp: 1,
                confidence: 1,
                words: [
                    AlignmentSidecar.Anchor.Word(word: "let", start: 1, end: 1.1),
                    AlignmentSidecar.Anchor.Word(word: "value", start: 1.1, end: 1.2),
                    AlignmentSidecar.Anchor.Word(word: "=", start: 1.2, end: 1.3),
                    AlignmentSidecar.Anchor.Word(word: "answer", start: 1.3, end: 1.4),
                    AlignmentSidecar.Anchor.Word(word: "+", start: 1.4, end: 1.5),
                    AlignmentSidecar.Anchor.Word(word: "42", start: 1.5, end: 1.6),
                ],
                sourceBlockIdentity: AlignmentSidecar.sourceIdentity(for: code)
            )
        ]

        do {
            _ = try AlignmentSidecarVerifier.verify(
                anchors: anchors,
                blocks: [code],
                chapterTimings: [.init(index: 0, start: 0, end: 10)],
                audioDuration: 10)
            Issue.record("Expected raw-code word count verification to fail.")
        } catch let error as AlignmentSidecarVerifier.VerificationError {
            #expect(
                error.issues.contains(
                    .wordCountMismatch(blockID: "s0-b0", words: 6, expected: 3)))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func verifyReportsUnresolvedNonMonotonicOutOfRangeAndEmptyChapterIssues() {
        let blocks = [
            block(spine: 0, index: 0, sequence: 0, words: 1, text: "A"),
            block(spine: 1, index: 0, sequence: 1, words: 1, text: "B"),
        ]
        let chapters = [
            EstimatedAlignmentSidecar.ChapterTiming(index: 0, start: 0, end: 10),
            EstimatedAlignmentSidecar.ChapterTiming(index: 1, start: 10, end: 20),
        ]
        let anchors = [
            AlignmentSidecar.Anchor(blockId: "s0-b0", timestamp: 12, confidence: 0.5),
            AlignmentSidecar.Anchor(blockId: "s9-b9", timestamp: 8, confidence: 0.5),
            AlignmentSidecar.Anchor(blockId: "s1-b0", timestamp: 30, confidence: 0.5),
        ]

        do {
            _ = try AlignmentSidecarVerifier.verify(
                anchors: anchors,
                blocks: blocks,
                chapterTimings: chapters,
                audioDuration: 20
            )
            Issue.record("Expected sidecar verification to fail.")
        } catch let error as AlignmentSidecarVerifier.VerificationError {
            #expect(error.issues.contains(.unresolvedBlockID("s9-b9")))
            #expect(error.issues.contains(.timestampDecreased(blockID: "s9-b9", timestamp: 8)))
            #expect(error.issues.contains(.timestampOutOfRange(blockID: "s1-b0", timestamp: 30)))
            #expect(error.issues.contains(.chapterWithoutAnchors(index: 0)))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func verifyAcceptsAnchorsCarryingConsistentWordTimings() throws {
        let blocks = [
            block(spine: 0, index: 0, sequence: 0, words: 2, text: "Hello there"),
            block(spine: 1, index: 0, sequence: 1, words: 1, text: "Goodbye"),
        ]
        let chapters = [
            EstimatedAlignmentSidecar.ChapterTiming(index: 0, start: 0, end: 10),
            EstimatedAlignmentSidecar.ChapterTiming(index: 1, start: 10, end: 20),
        ]
        let anchors = [
            AlignmentSidecar.Anchor(
                blockId: "s0-b0", timestamp: 0, confidence: 1,
                words: [
                    AlignmentSidecar.Anchor.Word(word: "Hello", start: 0.0, end: 0.4),
                    AlignmentSidecar.Anchor.Word(word: "there", start: 0.4, end: 0.9),
                ]),
            // A word-less anchor in the same sidecar stays valid.
            AlignmentSidecar.Anchor(blockId: "s1-b0", timestamp: 10, confidence: 1),
        ]

        let report = try AlignmentSidecarVerifier.verify(
            anchors: anchors,
            blocks: blocks,
            chapterTimings: chapters,
            audioDuration: 20
        )

        #expect(report.anchorCount == 2)
        #expect(report.chapterCount == 2)
        #expect(report.anchorsWithWords == 1)
    }

    @Test func verifyWordlessSidecarReportsZeroWordAnchors() throws {
        let blocks = [
            block(spine: 0, index: 0, sequence: 0, words: 1, text: "A")
        ]
        let chapters = [
            EstimatedAlignmentSidecar.ChapterTiming(index: 0, start: 0, end: 10)
        ]
        let anchors = [
            AlignmentSidecar.Anchor(blockId: "s0-b0", timestamp: 0, confidence: 0.5)
        ]

        let report = try AlignmentSidecarVerifier.verify(
            anchors: anchors,
            blocks: blocks,
            chapterTimings: chapters,
            audioDuration: 10
        )

        #expect(report.anchorCount == 1)
        #expect(report.anchorsWithWords == 0)
    }

    @Test func verifyReportsEmptyWordListAndWordCountMismatch() {
        let blocks = [
            block(spine: 0, index: 0, sequence: 0, words: 2, text: "Hello there"),
            block(spine: 1, index: 0, sequence: 1, words: 1, text: "Goodbye"),
        ]
        let chapters = [
            EstimatedAlignmentSidecar.ChapterTiming(index: 0, start: 0, end: 10),
            EstimatedAlignmentSidecar.ChapterTiming(index: 1, start: 10, end: 20),
        ]
        let anchors = [
            AlignmentSidecar.Anchor(blockId: "s0-b0", timestamp: 0, confidence: 1, words: []),
            AlignmentSidecar.Anchor(
                blockId: "s1-b0", timestamp: 10, confidence: 1,
                words: [
                    AlignmentSidecar.Anchor.Word(word: "Goodbye", start: 10, end: 10.5),
                    AlignmentSidecar.Anchor.Word(word: "extra", start: 10.5, end: 11),
                ]),
        ]

        do {
            _ = try AlignmentSidecarVerifier.verify(
                anchors: anchors,
                blocks: blocks,
                chapterTimings: chapters,
                audioDuration: 20
            )
            Issue.record("Expected word verification to fail.")
        } catch let error as AlignmentSidecarVerifier.VerificationError {
            #expect(error.issues.contains(.emptyWordList(blockID: "s0-b0")))
            #expect(
                error.issues.contains(
                    .wordCountMismatch(blockID: "s1-b0", words: 2, expected: 1)))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func verifyReportsNonMonotonicInvertedAndPreAnchorWordTimes() {
        let blocks = [
            block(spine: 0, index: 0, sequence: 0, words: 3, text: "one two three"),
            block(spine: 1, index: 0, sequence: 1, words: 2, text: "four five"),
        ]
        let chapters = [
            EstimatedAlignmentSidecar.ChapterTiming(index: 0, start: 0, end: 10),
            EstimatedAlignmentSidecar.ChapterTiming(index: 1, start: 10, end: 20),
        ]
        let anchors = [
            AlignmentSidecar.Anchor(
                blockId: "s0-b0", timestamp: 1, confidence: 1,
                words: [
                    // Starts 0.5s before its anchor — beyond the epsilon.
                    AlignmentSidecar.Anchor.Word(word: "one", start: 0.5, end: 1.2),
                    // Start decreased vs the previous word.
                    AlignmentSidecar.Anchor.Word(word: "two", start: 0.3, end: 1.6),
                    // start > end.
                    AlignmentSidecar.Anchor.Word(word: "three", start: 2.0, end: 1.8),
                ]),
            AlignmentSidecar.Anchor(
                blockId: "s1-b0", timestamp: 10, confidence: 1,
                words: [
                    AlignmentSidecar.Anchor.Word(word: "four", start: 10, end: 10.5),
                    AlignmentSidecar.Anchor.Word(word: "five", start: 10.5, end: 11),
                ]),
        ]

        do {
            _ = try AlignmentSidecarVerifier.verify(
                anchors: anchors,
                blocks: blocks,
                chapterTimings: chapters,
                audioDuration: 20
            )
            Issue.record("Expected word verification to fail.")
        } catch let error as AlignmentSidecarVerifier.VerificationError {
            #expect(
                error.issues.contains(
                    .wordStartsBeforeAnchor(blockID: "s0-b0", start: 0.5, anchor: 1)))
            #expect(error.issues.contains(.wordStartDecreased(blockID: "s0-b0", wordIndex: 1)))
            #expect(error.issues.contains(.wordRangeInvalid(blockID: "s0-b0", wordIndex: 2)))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func audioTimingReaderUsesM4BChapterMarkers() async throws {
        let source = try await SilentAudioFixture.makeSilentM4A(seconds: 6)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4b")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }

        try await ChapterMarkerWriter().writeChapters(
            [
                ChapterAtom(startTime: 0, title: "Intro"),
                ChapterAtom(startTime: 3, title: "Body"),
            ],
            to: source,
            outputURL: output
        )

        let result = try await ChapteredAudioTimingReader.timings(at: output)

        #expect(abs(result.duration - 6) < 0.25)
        #expect(result.chapterTimings.map(\.index) == [0, 1])
        #expect(abs(result.chapterTimings[0].start - 0) < 0.25)
        #expect(abs(result.chapterTimings[0].end - 3) < 0.25)
        #expect(abs(result.chapterTimings[1].start - 3) < 0.25)
        #expect(abs(result.chapterTimings[1].end - 6) < 0.25)
    }

    @Test func audioTimingReaderTreatsAudioDirectoryAsSortedChapterFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let firstSource = try await SilentAudioFixture.makeSilentM4A(seconds: 1)
        let secondSource = try await SilentAudioFixture.makeSilentM4A(seconds: 2)
        let first = directory.appendingPathComponent("01-intro.m4a")
        let second = directory.appendingPathComponent("02-body.m4a")
        try FileManager.default.moveItem(at: firstSource, to: first)
        try FileManager.default.moveItem(at: secondSource, to: second)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try await ChapteredAudioTimingReader.timings(at: directory)

        #expect(abs(result.duration - 3) < 0.25)
        #expect(result.chapterTimings.map(\.index) == [0, 1])
        #expect(abs(result.chapterTimings[0].start - 0) < 0.25)
        #expect(abs(result.chapterTimings[0].end - 1) < 0.25)
        #expect(abs(result.chapterTimings[1].start - 1) < 0.25)
        #expect(abs(result.chapterTimings[1].end - 3) < 0.25)
    }

    @Test func sourceBlockLoaderImportsZippedEPUBWithPortableBlockSuffixes() async throws {
        let fixtureURL = try #require(
            Bundle(for: EstimatedSidecarFixtureBundleLocator.self)
                .url(forResource: "minimal-book", withExtension: "epub"),
            "minimal-book.epub is missing from the EchoTests bundle resources"
        )
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sourceURL = folder.appendingPathComponent("minimal-book.epub")
        try FileManager.default.copyItem(at: fixtureURL, to: sourceURL)
        let audiobookID = "sidecar-test-\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(at: folder)
            cleanupEPUBCache(audiobookID: audiobookID)
        }

        let blocks = try await SidecarSourceBlockLoader.blocks(
            from: sourceURL,
            audiobookID: audiobookID
        )

        #expect(!blocks.isEmpty)
        #expect(Set(blocks.map(\.spineIndex)) == Set([0, 1]))
        #expect(blocks.map { AlignmentSidecar.portableSuffix(of: $0.id) }.contains("s0-b0"))
    }

    private func block(
        spine: Int,
        index: Int,
        sequence: Int,
        kind: EPubBlockRecord.Kind = .paragraph,
        words: Int,
        text: String?,
        isHidden: Bool = false
    ) -> EPubBlockRecord {
        EPubBlockRecord(
            id: "epub-book-s\(spine)-b\(index)",
            audiobookID: "book",
            spineHref: "ch\(spine).xhtml",
            spineIndex: spine,
            blockIndex: index,
            sequenceIndex: sequence,
            blockKind: kind.rawValue,
            text: text,
            htmlContent: nil,
            cardColor: nil,
            chapterThemeColor: nil,
            imagePath: nil,
            chapterIndex: nil,
            isHidden: isHidden,
            hiddenReason: nil,
            isFrontMatter: false,
            wordCount: words,
            markers: nil,
            textFormats: nil,
            narrationText: nil,
            createdAt: nil,
            modifiedAt: nil
        )
    }

    private func cleanupEPUBCache(audiobookID: String) {
        let safeID = SafeFileName.fromAudiobookID(audiobookID)
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(
                at:
                    caches
                    .appendingPathComponent("EPUBUnpacked", isDirectory: true)
                    .appendingPathComponent(safeID, isDirectory: true)
            )
        }
        if let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            try? FileManager.default.removeItem(
                at:
                    appSupport
                    .appendingPathComponent("EPUBAssets", isDirectory: true)
                    .appendingPathComponent(safeID, isDirectory: true)
            )
        }
    }
}
