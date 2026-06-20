// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct ABSLibraryDirectoryTests {
    @Test func pathIsUnderApplicationSupportABSLibrary() {
        let url = FileLocations.absLibraryDirectory(remoteItemID: "item-abc")
        #expect(url.deletingLastPathComponent().lastPathComponent == "ABSLibrary")
        #expect(url.lastPathComponent == "item-abc")
        #expect(url.path.contains("ABSLibrary/item-abc"))
    }
}
