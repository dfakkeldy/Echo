// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct WidgetAccentColorTests {
    @Test("six-digit cover accents parse into RGB components")
    func parsesCoverAccent() throws {
        let rgb = try #require(HexRGB(hex: "#FF8000"))

        #expect(rgb.red == 1)
        #expect(rgb.green == 128.0 / 255.0)
        #expect(rgb.blue == 0)
        #expect(HexRGB(hex: "#12345") == nil)
        #expect(HexRGB(hex: "#GG0000") == nil)
    }

    @Test("exact cover RGB is selected only when the surface preserves it")
    func selectsCoverAccentOnlyForFullColor() throws {
        let rgb = try #require(HexRGB(hex: "#FF8000"))

        #expect(
            WidgetProgressAccentPolicy.style(
                accentHex: "#FF8000",
                preservesExactCoverColor: true
            ) == .cover(rgb)
        )
        #expect(
            WidgetProgressAccentPolicy.style(
                accentHex: "#FF8000",
                preservesExactCoverColor: false
            ) == .systemTint
        )
    }

    @Test("missing cleared and malformed accents use system tint")
    func invalidAccentsUseSystemTint() {
        #expect(
            WidgetProgressAccentPolicy.style(
                accentHex: nil,
                preservesExactCoverColor: true
            ) == .systemTint
        )
        #expect(
            WidgetProgressAccentPolicy.style(
                accentHex: "",
                preservesExactCoverColor: true
            ) == .systemTint
        )
        #expect(
            WidgetProgressAccentPolicy.style(
                accentHex: "#GG0000",
                preservesExactCoverColor: true
            ) == .systemTint
        )
    }
}
