// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct MacVisualListeningParityTests {
    @Test func triPaneHostsVisualListeningStageBesideReader() throws {
        let triPane = try MacSource.read("Views/MacTriPaneView.swift")

        #expect(
            triPane.contains("VisualListeningViewModel"),
            "MacTriPaneView should load visual-listening snapshots from the shared view model."
        )
        #expect(
            triPane.contains("MacVisualStageView("),
            "macOS should mount a visual listening stage in the center workspace."
        )
        #expect(
            triPane.contains("MacReaderFeedView()"),
            "The visual stage must augment the reader, not replace it."
        )
        #expect(
            triPane.contains("player.currentTime"),
            "The macOS stage should update from live playback time."
        )
        #expect(
            triPane.contains("player.currentTrackChapterIndices"),
            "The macOS stage should use the same track scope semantics as the reader."
        )
        #expect(
            triPane.contains("visualListeningViewModel?.hasVisualListeningContent == true"),
            "The macOS stage should only appear when both image and subtitle cues are available."
        )
        #expect(
            triPane.contains("snapshot.subtitleCue != nil"),
            "The macOS visual stage should only appear with a subtitle cue."
        )
    }

    @Test func macVisualStageKeepsSubtitlesTimingChoiceAndImageLoading() throws {
        let stage = try MacSource.read("Views/MacVisualStageView.swift")

        #expect(stage.contains("Image(decorative: cgImage, scale: 1)"))
        #expect(stage.contains("Picker(\"Visual timing\""))
        #expect(stage.contains(".accessibilityLabel(Text(\"Visual timing\"))"))
        #expect(!stage.contains("\"Image timing\""))
        #expect(stage.contains("Subtitle:"))
        #expect(stage.contains("Current figure"))
        #expect(stage.contains("WordTokenizer.wordRanges"))
        #expect(stage.contains("SafeFileName.fromAudiobookID"))
    }

    @Test func macVisualStageRendersSelectableTwoAxisCodeListings() throws {
        let stage = try MacSource.read("Views/MacVisualStageView.swift")
        let codeView = try Self.privateStruct(named: "VisualListeningCodeView", in: stage)

        #expect(stage.contains("if case .code(let text, _) = snapshot.visualCue?.content"))
        #expect(codeView.contains("ScrollView([.vertical, .horizontal])"))
        #expect(codeView.contains("Text(text)"))
        #expect(codeView.contains(".font(.system(.callout, design: .monospaced))"))
        #expect(codeView.contains(".textSelection(.enabled)"))
        #expect(codeView.contains(".scrollIndicators(.hidden)"))
        #expect(!codeView.contains(".accessibilityHidden(true)"))
        #expect(codeView.contains(".accessibilityValue(Text(text))"))
        #expect(stage.contains("Current code listing"))
    }

    @Test func iOSVisualStageMatchesSelectableTwoAxisCodeRendering() throws {
        let stage = try Self.readProjectSource("EchoCore/Views/VisualListeningStageView.swift")
        let codeView = try Self.privateStruct(named: "VisualListeningCodeView", in: stage)

        #expect(stage.contains("if case .code(let text, _) = snapshot.visualCue?.content"))
        #expect(codeView.contains("ScrollView([.vertical, .horizontal])"))
        #expect(codeView.contains("Text(text)"))
        #expect(codeView.contains(".font(.system(.callout, design: .monospaced))"))
        #expect(codeView.contains(".textSelection(.enabled)"))
        #expect(codeView.contains(".scrollIndicators(.hidden)"))
        #expect(!codeView.contains(".accessibilityHidden(true)"))
        #expect(codeView.contains(".accessibilityValue(Text(text))"))
        #expect(stage.contains("Current code listing"))
    }

    @Test func iOSCodeViewportReservesSubtitleSpace() throws {
        let stage = try Self.readProjectSource("EchoCore/Views/VisualListeningStageView.swift")
        let codeView = try Self.privateStruct(named: "VisualListeningCodeView", in: stage)

        #expect(
            stage.contains("if !isCodeVisual, let subtitleCue = snapshot.subtitleCue"),
            "Image subtitles should retain their overlay while code subtitles move into reserved space."
        )
        #expect(
            codeView.contains(".safeAreaInset(edge: .bottom, spacing: 0)"),
            "The code scroll view must reserve the subtitle's actual layout height."
        )
        #expect(codeView.contains("VisualListeningSubtitleView(cue: subtitleCue"))
    }

    @Test func macTrackScopeUsesSharedResolver() throws {
        let scope = try MacSource.read("Views/MacPlayerModel+VisualListeningScope.swift")

        #expect(scope.contains("ReaderActiveBlockResolver.trackChapterScope"))
        #expect(scope.contains("currentTrackIndex"))
        #expect(scope.contains("isMultiM4B: false"))
    }

    private enum SourceError: Error {
        case notFound(String)
        case privateStructNotFound(String)
    }

    private static func readProjectSource(_ relativePath: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.deletingLastPathComponent().appending(path: relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            directory.deleteLastPathComponent()
        }
        throw SourceError.notFound(relativePath)
    }

    private static func privateStruct(named name: String, in source: String) throws -> String {
        let marker = "private struct \(name)"
        guard let start = source.range(of: marker) else {
            throw SourceError.privateStructNotFound(name)
        }
        let remainder = source[start.lowerBound...]
        let end =
            remainder.dropFirst(marker.count).range(of: "\nprivate struct ")?.lowerBound
            ?? source.endIndex
        return String(source[start.lowerBound..<end])
    }
}
