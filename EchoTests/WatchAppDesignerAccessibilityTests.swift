// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

struct WatchAppDesignerAccessibilityTests {
    @Test func watchDesignerOffersNonDragSlotPickers() throws {
        let source = try Self.source(named: "WatchAppSettingsView.swift")
        #expect(
            source.contains("WatchSlotPickerGrid("),
            "Watch App Designer must offer a non-drag picker path for configuring slots."
        )
        #expect(
            source.contains("choices: watchSlotChoices"),
            "Watch slot pickers must use the same selectable action set as the drag palette plus Empty."
        )
        #expect(
            !source.contains("Available Actions (Drag to slots)"),
            "Watch App Designer copy must not imply dragging is the only configuration path."
        )

        let pickerSlice = try Self.slice(
            of: source,
            after: "private struct WatchSlotPickerGrid",
            until: "private struct PaletteItem"
        )
        #expect(
            pickerSlice.contains("ForEach(0..<5"),
            "Watch slot pickers must cover all five slots on the selected page."
        )
        #expect(
            pickerSlice.contains("Picker("),
            "Watch slot controls must use standard Picker controls instead of drag-only interaction."
        )
        #expect(
            pickerSlice.contains("slotBinding(for: slot)"),
            "Each Watch slot picker must bind directly to the corresponding slot."
        )
        #expect(
            pickerSlice.contains("onChange()"),
            "Watch slot picker changes must persist and sync through the existing save path."
        )
        #expect(
            source.contains("Task { @MainActor in"),
            "Watch drag-and-drop persistence should hop back to the main actor with Swift concurrency."
        )
    }

    private static func source(named fileName: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate =
                directory
                .deletingLastPathComponent()
                .appending(path: "EchoCore/Views")
                .appending(path: fileName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func slice(of source: String, after: String, until: String) throws -> String {
        guard let startRange = source.range(of: after) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let tail = source[startRange.upperBound...]
        guard let endRange = tail.range(of: until) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return String(tail[..<endRange.lowerBound])
    }
}
