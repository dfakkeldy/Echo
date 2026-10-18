// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

struct WatchPomodoroAccessibilitySourceTests {
    @Test("Pomodoro exposes large digits and a discoverable duration action")
    func pomodoroAccessibilityContract() throws {
        let source = try Self.source()

        #expect(source.contains("PomodoroTimePresentation.make"))
        #expect(source.contains("ViewThatFits"))
        #expect(source.contains("textStyle: .headline"))
        #expect(source.contains("textStyle: .subheadline"))
        #expect(source.contains("textStyle: .caption"))
        #expect(!source.contains("textStyle: .title2"))
        #expect(source.contains(".system(textStyle"))
        #expect(!source.contains(".system(size:"))
        #expect(
            source.components(separatedBy: ".inset(by: strokeWidth / 2)").count == 3
        )
        let background = try #require(
            source.range(of: "WatchControlBackground(shape: Circle())")
        )
        let track = try #require(source.range(of: "// Background track"))
        #expect(background.lowerBound < track.lowerBound)
        #expect(source.contains(".accessibilityLabel(\"Pomodoro timer\")"))
        #expect(source.contains(".accessibilityValue("))
        #expect(source.contains("presentation.accessibilityHint"))
        #expect(source.contains(".accessibilityAction(named: \"Set duration\")"))
    }

    private static func source() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appending(
                path: "Echo Watch App/Views/Components/PomodoroButton.swift"
            ),
            encoding: .utf8
        )
    }
}
