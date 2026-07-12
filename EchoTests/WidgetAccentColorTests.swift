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
}
