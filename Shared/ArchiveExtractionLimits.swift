// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Size ceilings that guard archive extraction (`.apkg`, `.epub`) against
/// decompression-bomb / zip-bomb denial of service — a small compressed archive
/// that expands to gigabytes and exhausts temporary disk during import
/// (audit §6.1). Zip-slip (path traversal) is handled separately by each
/// scanner's `safeDestination`.
nonisolated enum ArchiveExtractionLimits {
    /// Largest single entry we will extract (uncompressed bytes).
    static let maxEntryBytes: UInt64 = 100 * 1024 * 1024  // 100 MB
    /// Largest cumulative extraction across all entries in one archive.
    static let maxTotalBytes: UInt64 = 512 * 1024 * 1024  // 512 MB

    nonisolated struct Budget: Equatable, Sendable {
        let maxEntryBytes: UInt64
        let maxTotalBytes: UInt64

        static let generic = Budget(
            maxEntryBytes: ArchiveExtractionLimits.maxEntryBytes,
            maxTotalBytes: ArchiveExtractionLimits.maxTotalBytes)

        /// ABS whole-item archives can legitimately contain large audiobook files.
        /// Keep the generic EPUB/APKG limits tight, but allow multi-gigabyte audio
        /// while still rejecting absurd declared expansion sizes before extraction.
        static let absWholeAudiobook = Budget(
            maxEntryBytes: 2 * 1024 * 1024 * 1024,   // 2 GB per file
            maxTotalBytes: 8 * 1024 * 1024 * 1024)   // 8 GB per item
    }

    enum LimitError: LocalizedError, Equatable {
        case entryTooLarge(size: UInt64, limit: UInt64)
        case totalTooLarge(total: UInt64, limit: UInt64)

        var errorDescription: String? {
            switch self {
            case .entryTooLarge(let size, let limit):
                "Archive entry is \(size) bytes, over the \(limit)-byte per-entry limit."
            case .totalTooLarge(let total, let limit):
                "Archive expands to \(total) bytes, over the \(limit)-byte total limit."
            }
        }
    }

    /// Adds `entrySize` to `runningTotal`, throwing `LimitError` if either the
    /// per-entry cap or the cumulative cap would be exceeded. Returns the new
    /// running total so callers can thread it through an extraction loop.
    ///
    /// This checks the archive's *declared* uncompressed size, which stops the
    /// classic zip bomb that advertises a huge expansion. A hostile archive can
    /// under-report; a streaming byte counter on the written output would be the
    /// stronger guard and is a worthwhile follow-up.
    static func checkedTotal(
        addingEntryOfSize entrySize: UInt64,
        to runningTotal: UInt64,
        budget: Budget = .generic
    ) throws
        -> UInt64
    {
        guard entrySize <= budget.maxEntryBytes else {
            throw LimitError.entryTooLarge(size: entrySize, limit: budget.maxEntryBytes)
        }
        let newTotal = runningTotal &+ entrySize
        guard newTotal >= runningTotal, newTotal <= budget.maxTotalBytes else {
            throw LimitError.totalTooLarge(total: newTotal, limit: budget.maxTotalBytes)
        }
        return newTotal
    }
}
