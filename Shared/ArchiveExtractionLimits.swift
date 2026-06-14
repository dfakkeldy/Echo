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
    static func checkedTotal(addingEntryOfSize entrySize: UInt64, to runningTotal: UInt64) throws
        -> UInt64
    {
        guard entrySize <= maxEntryBytes else {
            throw LimitError.entryTooLarge(size: entrySize, limit: maxEntryBytes)
        }
        let newTotal = runningTotal &+ entrySize
        guard newTotal >= runningTotal, newTotal <= maxTotalBytes else {
            throw LimitError.totalTooLarge(total: newTotal, limit: maxTotalBytes)
        }
        return newTotal
    }
}
