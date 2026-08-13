// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated struct ApkgIDAllocator: Sendable {
    struct IDPair: Sendable {
        let noteID: Int64
        let cardID: Int64
    }

    private let baseID: Int64

    init(baseID: Int64 = Self.currentEpochMilliseconds()) {
        self.baseID = baseID
    }

    func ids(forCardAt index: Int) -> IDPair {
        precondition(index >= 0, "APKG card index must be non-negative")
        let noteID = baseID + Int64(index) * 2
        return IDPair(noteID: noteID, cardID: noteID + 1)
    }

    private static func currentEpochMilliseconds(now: Date = .now) -> Int64 {
        Int64(now.timeIntervalSince1970 * 1_000)
    }
}
