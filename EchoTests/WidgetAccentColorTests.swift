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

    // MARK: - Background ramp

    @Test("the ramp is taken only when both ends survive parsing")
    func rampNeedsBothEnds() throws {
        let top = try #require(HexRGB(hex: "#3A2A12"))
        let bottom = try #require(HexRGB(hex: "#2C1F0D"))

        #expect(
            WidgetCoverRampPolicy.style(
                topHex: "#3A2A12",
                bottomHex: "#2C1F0D",
                preservesExactCoverColor: true
            ) == .ramp(top: top, bottom: bottom)
        )

        // A gradient built from one good hex and one fallback is not the
        // cover's ramp, so a half-parsed pair yields the system backing.
        for (topHex, bottomHex) in [
            ("#GG0000", "#2C1F0D"), ("#3A2A12", "#GG0000"), (nil, "#2C1F0D"), ("#3A2A12", nil),
        ] as [(String?, String?)] {
            #expect(
                WidgetCoverRampPolicy.style(
                    topHex: topHex,
                    bottomHex: bottomHex,
                    preservesExactCoverColor: true
                ) == .systemBacking
            )
        }
    }

    @Test("tinted and vibrant faces keep the system backing")
    func rampYieldsOutsideFullColor() {
        #expect(
            WidgetCoverRampPolicy.style(
                topHex: "#3A2A12",
                bottomHex: "#2C1F0D",
                preservesExactCoverColor: false
            ) == .systemBacking
        )
    }
}
