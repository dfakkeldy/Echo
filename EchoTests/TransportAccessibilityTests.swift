// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

struct TransportAccessibilityTests {
    @Test func transportLongPressActionsHaveNamedAccessibilityAlternatives() throws {
        let source = try Self.source("EchoCore/Views/TransportControlsView+LongPress.swift")

        #expect(
            source.contains("Button(action: tapAction) { content() }"),
            "Transport buttons with secondary actions must keep their primary tap on the semantic Button."
        )
        #expect(
            source.contains(".accessibilityAction( named: Text(secondaryAccessibilityActionName"),
            "Transport buttons must expose configured secondary actions through named accessibility actions."
        )
        #expect(
            source.contains("executeSecondaryAction(longPressAction, model: model)"),
            "The accessibility action must call the same secondary-action executor as the long press."
        )
        #expect(
            source.contains("func phoneLongPressGesture(action: WatchAction, model: PlayerModel)"),
            "Menu-based transport slots must keep their long-press fallback hook."
        )
        #expect(
            source.contains("executeSecondaryAction(action, model: model)"),
            "Menu-based transport slots must expose their fallback through the same accessibility executor."
        )
    }

    @Test func scrubberJoystickExposesAdjustableAndNamedActions() throws {
        let source = try Self.source("EchoCore/Views/ScrubberJoystick.swift")

        #expect(
            source.contains(".accessibilityAdjustableAction"),
            "ScrubberJoystick must support VoiceOver adjustable actions for non-drag scrubbing."
        )
        #expect(
            source.contains("case .increment: adjustScrubbing(by: accessibilityStep)"),
            "ScrubberJoystick adjustable increment must scrub forward."
        )
        #expect(
            source.contains("case .decrement: adjustScrubbing(by: -accessibilityStep)"),
            "ScrubberJoystick adjustable decrement must scrub backward."
        )

        for actionName in ["Scrub forward", "Scrub backward", "Stop scrubbing"] {
            #expect(
                source.contains(".accessibilityAction(named: Text(\"\(actionName)\"))"),
                "ScrubberJoystick must expose the \(actionName) named accessibility action."
            )
        }

        #expect(
            source.contains("private func setScrubValue(_ newValue: Double)"),
            "ScrubberJoystick must route accessibility updates through the same clamping path as drag updates."
        )
    }

    private static func source(_ relativePath: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.deletingLastPathComponent().appending(path: relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                let raw = try String(contentsOf: candidate, encoding: .utf8)
                return raw.replacingOccurrences(
                    of: "\\s+", with: " ", options: .regularExpression)
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
