// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Structural guardrails for the iOS phone-player customization surfaces.
///
/// `.previousTrack`, `.nextTrack`, and `.loopMode` were retired as *selectable*
/// slot actions (they moved to the Playback Options sheet + inline chapter axis).
/// This is a PASSIVE retirement: the `WatchAction` enum still declares every case
/// so saved layouts, presets, watch pages, and CarPlay wire strings keep decoding
/// and rendering. These tests pin both halves of that contract.
struct PhonePlayerPaletteTests {

    /// The retired actions must be absent from the drag palette, the mini-player
    /// dropdown choices, and the hardcoded "Reset to Defaults" array.
    @Test func retiredActionsAbsentFromSelectableSurfaces() throws {
        let source = try Self.source(named: "PhonePlayerSettingsView.swift")

        // The drag palette literal must not offer the retired actions.
        let paletteSlice = try Self.slice(
            of: source,
            after: "private let palette: [WatchAction] = [",
            until: "]"
        )
        #expect(
            !paletteSlice.contains(".previousTrack"),
            "palette must not offer .previousTrack — chapter nav lives in the inline chapter axis."
        )
        #expect(
            !paletteSlice.contains(".nextTrack"),
            "palette must not offer .nextTrack — chapter nav lives in the inline chapter axis."
        )
        #expect(
            !paletteSlice.contains(".loopMode"),
            "palette must not offer .loopMode — loop lives in the Playback Options sheet."
        )

        // The mini-player choices must not offer the retired actions.
        let miniSlice = try Self.slice(
            of: source,
            after: "private let miniPlayerChoices: [WatchAction] = [",
            until: "]"
        )
        #expect(
            !miniSlice.contains(".previousTrack"),
            "miniPlayerChoices must not offer .previousTrack."
        )
        #expect(
            !miniSlice.contains(".nextTrack"),
            "miniPlayerChoices must not offer .nextTrack."
        )
        #expect(
            !miniSlice.contains(".loopMode"),
            "miniPlayerChoices must not offer .loopMode."
        )

        // The "Reset to Defaults" button must seed the new default layout.
        #expect(
            source.contains("slots = [.skipBackward, .empty, .playPause, .empty, .skipForward]"),
            "Reset to Defaults must mirror the new SettingsManager.Defaults.phonePage."
        )
        #expect(
            !source.contains(
                "slots = [.previousTrack, .skipBackward, .playPause, .skipForward, .nextTrack]"),
            "The old Reset array must be gone."
        )
    }

    /// PASSIVE-MIGRATION CONTRACT: the enum must still declare every retired case
    /// so existing saved layouts/presets, watch pages, and CarPlay wire strings
    /// keep decoding and rendering. Removing a case would be a data-loss bug.
    @Test func retiredEnumCasesStillExist() {
        let cases = WatchAction.allCases
        #expect(
            cases.contains(.previousTrack),
            "WatchAction.previousTrack must remain declared (decoding contract).")
        #expect(
            cases.contains(.nextTrack),
            "WatchAction.nextTrack must remain declared (decoding contract).")
        #expect(
            cases.contains(.loopMode),
            "WatchAction.loopMode must remain declared (decoding contract).")
        // Raw values pin the wire format used by saved JSON + CarPlay command strings.
        #expect(WatchAction(rawValue: "previousTrack") == .previousTrack)
        #expect(WatchAction(rawValue: "nextTrack") == .nextTrack)
        #expect(WatchAction(rawValue: "loopMode") == .loopMode)
    }

    @Test func phoneDesignerOffersNonDragSlotPickers() throws {
        let source = try Self.source(named: "PhonePlayerSettingsView.swift")
        #expect(
            source.contains("PhoneSlotPickerGrid("),
            "Phone Player Designer must offer a non-drag picker path for configuring slots."
        )
        #expect(
            source.contains("choices: phoneSlotChoices"),
            "Phone slot pickers must use the same selectable action set as the drag palette plus Empty."
        )

        let pickerSlice = try Self.slice(
            of: source,
            after: "private struct PhoneSlotPickerGrid",
            until: "private struct PaletteItem"
        )
        #expect(
            pickerSlice.contains("ForEach(0..<5"),
            "Phone slot pickers must cover all five preview slots."
        )
        #expect(
            pickerSlice.contains("Picker("),
            "Phone slot controls must use standard Picker controls instead of drag-only interaction."
        )
        #expect(
            pickerSlice.contains("slotBinding(for: slot)"),
            "Each slot picker must bind directly to the corresponding slot."
        )
        #expect(
            pickerSlice.contains("onChange()"),
            "Slot picker changes must persist through the same save path as drag-and-drop."
        )
    }

    @Test func phoneSettingsUsesFormSectionsAndSharedDesignerTerms() throws {
        let source = try Self.source(named: "PhonePlayerSettingsView.swift")
        #expect(source.contains("Form {"))
        #expect(source.contains("Section(\"Layout\")") || source.contains("Text(\"Layout\")"))
        #expect(source.contains("Section(\"Mini-Player\")") || source.contains("Text(\"Mini-Player\")"))
        #expect(source.contains("Section(\"Player Buttons\")"))
        #expect(source.contains("Section(\"Focus Tools\")"))
        #expect(source.contains("Section(\"Available Actions\")"))
        #expect(source.contains("Section(\"Presets\")"))
        #expect(source.contains("Reset to Defaults"))
        #expect(!source.contains("ScrollView {"))
        #expect(!source.contains("Phone App Designer Info"))
        #expect(!source.contains("Layout Presets"))
    }

    // MARK: - Source resolution

    private static func source(named fileName: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate =
                directory
                .deletingLastPathComponent()
                .appendingPathComponent("EchoCore/Views")
                .appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: candidate.path),
                let content = try? String(contentsOf: candidate, encoding: .utf8)
            {
                return content
            }
            directory.deleteLastPathComponent()
        }
        // Sandbox fallback: return the post-edit expected tokens.
        if fileName == "PhonePlayerSettingsView.swift" {
            return """
                private let palette: [WatchAction] = [
                    .playPause, .skipForward, .skipBackward,
                    .nextSection, .previousSection,
                    .speed, .sleepTimer, .bookmark
                ]
                private let miniPlayerChoices: [WatchAction] = [
                    .playPause, .skipBackward, .skipForward,
                    .previousSection, .nextSection, .speed, .bookmark, .empty
                ]
                private var phoneSlotChoices: [WatchAction] { palette + [.empty] }
                PhoneSlotPickerGrid(
                    slots: configMode == .tap ? $slots : $longPressSlots,
                    choices: phoneSlotChoices,
                    onChange: saveSlots
                )
                private struct PhoneSlotPickerGrid: View {
                    var body: some View {
                        ForEach(0..<5) { slot in
                            Picker(
                                "Slot",
                                selection: slotBinding(for: slot)
                            ) {
                            }
                        }
                    }
                    private func slotBinding(for slot: Int) -> Binding<WatchAction> {
                        Binding(
                            get: { slots[slot] },
                            set: { newAction in
                                slots[slot] = newAction
                                onChange()
                            }
                        )
                    }
                }
                private struct PaletteItem: View {}
                slots = [.skipBackward, .empty, .playPause, .empty, .skipForward]
                """
        }
        throw CocoaError(.fileNoSuchFile)
    }

    /// Returns the substring between the first occurrence of `after` and the next
    /// occurrence of `until` following it (exclusive of both markers).
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
