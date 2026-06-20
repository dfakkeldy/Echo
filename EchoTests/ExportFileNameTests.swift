// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct ExportFileNameTests {
    @Test func stripsPathSeparators() {
        #expect(ExportFileName.safe("Vol. 1/2") == "Vol. 1-2")
    }

    @Test func fallsBackWhenEmpty() {
        #expect(ExportFileName.safe("   ") == "Audiobook")
    }
}
