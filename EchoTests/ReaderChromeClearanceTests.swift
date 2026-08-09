// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct ReaderChromeClearanceTests {
    @Test func readerReservesDockAndMeasuredRootOverlay() {
        #expect(
            ReaderChromeClearance.bottomInset(
                dockHeight: 124,
                overlayHeight: 76
            ) == 200
        )
    }

    @Test func rootOwnsOverlayMeasurementAndThreadsItToBothReaderPaths() throws {
        let root = try source("RootTabView.swift")
        let reader = try source("ReaderTab.swift")
        let pdf = try source("PDFReadingSurface.swift")

        #expect(root.contains("readerOverlayContentHeight"))
        #expect(root.contains("readerOverlayClearance"))
        #expect(reader.contains("rootOverlayClearance"))
        #expect(pdf.contains("rootOverlayClearance"))
    }

    private func source(_ name: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath)
        while directory.path != "/" {
            let candidate = directory
                .deletingLastPathComponent()
                .appendingPathComponent("EchoCore/Views")
                .appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
