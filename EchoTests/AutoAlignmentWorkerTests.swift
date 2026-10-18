// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct AutoAlignmentWorkerTests {
    private func block(
        _ id: String,
        _ text: String,
        kind: EPubBlockRecord.Kind = .paragraph
    ) -> AutoAlignmentWorker.AlignmentBlock {
        AutoAlignmentWorker.AlignmentBlock(
            id: id,
            text: text,
            blockKind: kind.rawValue,
            isHidden: false)
    }

    private func word(_ text: String, _ time: TimeInterval) -> TranscribedWord {
        TranscribedWord(text: text, start: time)
    }

    private func epubTokens(_ blocks: [AutoAlignmentWorker.AlignmentBlock]) -> [TokenDTW.EPubToken]
    {
        blocks.flatMap { block in
            TokenDTW.normalize(block.text ?? "").map {
                TokenDTW.EPubToken(text: $0, blockID: block.id)
            }
        }
    }

    private func audioTokens(_ words: [TranscribedWord]) -> [TokenDTW.AudioToken] {
        words.flatMap { word in
            TokenDTW.normalize(word.text).map {
                TokenDTW.AudioToken(text: $0, time: word.start)
            }
        }
    }

    @Test func workerMatchesDirectDTWForSmallChapter() async throws {
        let blocks = [
            block("b-head", "Chapter 2"),
            block("b-sub", "Accepting Yourself and Your Partner"),
            block("b-para", "Couple interaction has often been compared to a dance"),
        ]
        let words = [
            word("chapter", 10.0), word("two", 10.4),
            word("accepting", 14.0), word("yourself", 14.4), word("and", 14.8),
            word("your", 15.2), word("partner", 15.6),
            word("couple", 20.0), word("interaction", 20.4), word("has", 20.8),
            word("often", 21.2), word("been", 21.6), word("compared", 22.0),
            word("to", 22.4), word("dance", 22.8),
        ]

        let output = try await AutoAlignmentWorker.alignChapter(
            AutoAlignmentWorker.Input(
                words: words,
                alignmentBlocks: blocks,
                anchoredBlockIDs: [],
                windowStart: 0,
                windowEnd: 60,
                lastGlobalAnchorTime: 0,
                minAnchorRunLength: 3
            )
        )

        let directEPub = epubTokens(blocks)
        let directAudio = audioTokens(words)
        let rawDirectCandidates = TokenDTW.alignWithBisection(epub: directEPub, audio: directAudio)
        let directCandidates = AnchorSelector.select(
            candidates: rawDirectCandidates,
            minRunLength: 3
        )
        let directMatches = Dictionary(
            grouping: TokenDTW.wordMatchesWithBisection(epub: directEPub, audio: directAudio),
            by: \.blockID
        )

        #expect(output.selectedCandidates == directCandidates)
        #expect(output.wordMatchesByBlock == directMatches)
        #expect(output.wordCount == words.count)
        #expect(output.candidateCount == rawDirectCandidates.count)
    }

    @Test func workerAppliesAnchoredWindowAndGlobalTimeGates() async throws {
        let blocks = [
            block("b-anchored", "alpha bravo charlie"),
            block("b-regression", "delta echo foxtrot"),
            block("b-kept", "golf hotel india"),
            block("b-late", "juliet kilo lima"),
        ]
        let words = [
            word("alpha", 10.0), word("bravo", 10.4), word("charlie", 10.8),
            word("delta", 20.0), word("echo", 20.4), word("foxtrot", 20.8),
            word("golf", 30.0), word("hotel", 30.4), word("india", 30.8),
            word("juliet", 40.0), word("kilo", 40.4), word("lima", 40.8),
        ]

        let output = try await AutoAlignmentWorker.alignChapter(
            AutoAlignmentWorker.Input(
                words: words,
                alignmentBlocks: blocks,
                anchoredBlockIDs: ["b-anchored"],
                windowStart: 15,
                windowEnd: 35,
                lastGlobalAnchorTime: 21,
                minAnchorRunLength: 3
            )
        )

        #expect(output.candidateCount == 4)
        #expect(output.selectedCandidates.map(\.blockID) == ["b-kept"])
        #expect(output.wordMatchesByBlock.keys.contains("b-anchored"))
        #expect(output.wordMatchesByBlock.keys.contains("b-late"))
    }

    @Test func workerExcludesCodeFromDTWTokenAndMatchOutput() async throws {
        let blocks = [
            block("code", "sentinel syntax tokens", kind: .code),
            block("prose", "spoken prose remains"),
        ]
        let words = [
            word("sentinel", 1.0), word("syntax", 1.4), word("tokens", 1.8),
            word("spoken", 3.0), word("prose", 3.4), word("remains", 3.8),
        ]

        let output = try await AutoAlignmentWorker.alignChapter(
            AutoAlignmentWorker.Input(
                words: words,
                alignmentBlocks: blocks,
                anchoredBlockIDs: [],
                windowStart: 0,
                windowEnd: 10,
                lastGlobalAnchorTime: 0,
                minAnchorRunLength: 1
            )
        )

        #expect(output.epubTokenCount == TokenDTW.normalize("spoken prose remains").count)
        #expect(!output.wordMatchesByBlock.keys.contains("code"))
        #expect(!output.selectedCandidates.contains { $0.blockID == "code" })
    }

    @Test func autoAlignmentServiceCarriesBlockKindIntoWorkerInput() throws {
        let source = try projectSource("EchoCore/Services/AutoAlignmentService.swift")
        #expect(source.contains("blockKind: $0.blockKind"))
    }

    @Test func cancellableDTWStopsDuringLargeLeafAlignment() async throws {
        let tokenCount = 4_000
        let epub = (0..<tokenCount).map {
            TokenDTW.EPubToken(text: "epub-\($0)", blockID: "b-\($0 / 8)")
        }
        let audio = (0..<tokenCount).map {
            TokenDTW.AudioToken(text: "audio-\($0)", time: TimeInterval($0) * 0.1)
        }

        let task = Task.detached {
            try await TokenDTW.alignWithBisectionCancellable(
                epub: epub,
                audio: audio,
                maxCells: Int.max
            )
        }

        try await Task.sleep(for: .milliseconds(1))
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    private func projectSource(_ relativePath: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.deletingLastPathComponent().appending(path: relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
