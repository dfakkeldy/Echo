// SPDX-License-Identifier: GPL-3.0-or-later
import ArgumentParser
import Foundation

/// Create an estimated block-level alignment sidecar for audio produced outside
/// Echo's native narration pipeline.
struct SidecarFromChapteredAudioCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sidecar-from-chaptered-audio",
        abstract: "Create an estimated alignment sidecar from EPUB/PDF source and chaptered audio.")

    @Option(help: "EPUB/PDF source file or directory; EPUB wins when both are present.")
    var epub: String
    @Option(help: "Chaptered M4B/M4A file or directory of per-chapter audio files.")
    var audio: String
    @Option(help: "Output .alignment.json path.")
    var out: String
    @Option(help: "Estimated-anchor confidence value.")
    var confidence: Double = 0.5

    @MainActor func run() async throws {
        let sourceURL = URL(fileURLWithPath: epub)
        let audioURL = URL(fileURLWithPath: audio)
        let outputURL = URL(fileURLWithPath: out)

        let blocks = try await SidecarSourceBlockLoader.blocks(from: sourceURL)
        let audioTiming = try await ChapteredAudioTimingReader.timings(at: audioURL)
        let anchors = try EstimatedAlignmentSidecar.build(
            blocks: blocks,
            chapterTimings: audioTiming.chapterTimings,
            confidence: confidence
        )
        let report = try AlignmentSidecarVerifier.verify(
            anchors: anchors,
            blocks: blocks,
            chapterTimings: audioTiming.chapterTimings,
            audioDuration: audioTiming.duration
        )

        try outputURL.createParentDirectoryIfNeeded()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(anchors).write(to: outputURL, options: .atomic)
        print(
            "SIDECAR_DONE \(outputURL.path) - \(report.anchorCount) anchors, \(report.chapterCount) chapters"
        )
    }
}

/// Verify that a sidecar can resolve against source blocks and audio chapter
/// timings before a fallback narration package is called Echo-ready.
struct VerifySidecarCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify-sidecar",
        abstract: "Verify an alignment sidecar against EPUB/PDF source and audio.")

    @Option(help: "EPUB/PDF source file or directory; EPUB wins when both are present.")
    var epub: String
    @Option(help: "Chaptered M4B/M4A file or directory of per-chapter audio files.")
    var audio: String
    @Option(help: "Sidecar .alignment.json path.")
    var sidecar: String

    @MainActor func run() async throws {
        let sourceURL = URL(fileURLWithPath: epub)
        let audioURL = URL(fileURLWithPath: audio)
        let sidecarURL = URL(fileURLWithPath: sidecar)

        let blocks = try await SidecarSourceBlockLoader.blocks(from: sourceURL)
        let audioTiming = try await ChapteredAudioTimingReader.timings(at: audioURL)
        let anchors = try AlignmentSidecar.decode(Data(contentsOf: sidecarURL))
        let report = try AlignmentSidecarVerifier.verify(
            anchors: anchors,
            blocks: blocks,
            chapterTimings: audioTiming.chapterTimings,
            audioDuration: audioTiming.duration
        )
        print(
            "SIDECAR_OK \(sidecarURL.path) - \(report.anchorCount) anchors, \(report.chapterCount) chapters"
        )
    }
}

extension URL {
    fileprivate func createParentDirectoryIfNeeded() throws {
        let parent = deletingLastPathComponent()
        guard parent.path != path else { return }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }
}
