// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ZIPFoundation

/// The sanctioned way to inflate an entry out of an untrusted ZIP archive.
///
/// **Invariant: every inflation performed through this type is bounded by
/// `min(entry.uncompressedSize, ceiling)` and aborts mid-stream.** The running
/// output total is checked *before* each inflated chunk is admitted, so a
/// hostile archive can never materialize more than that many bytes in memory or
/// on disk, whatever its central directory declares.
///
/// The bound lives here, below the call sites, rather than being repeated at
/// each of them, because nothing in the layers underneath supplies it:
///
/// - `Entry.uncompressedSize` is read from the central directory and is never
///   cross-checked against the local file header, so the declared size is
///   entirely attacker-controlled.
/// - ZIPFoundation bounds only the *compressed input*. `Data.decompress` caps
///   the bytes it reads and `Archive+Helpers` hands it `effectiveCompressedSize`;
///   no layer caps the bytes produced.
/// - `Archive.extract(_:to:)` builds its consumer as an unconditional
///   `Data.write(chunk:to:)`, so that overload writes every chunk it is handed.
///   Output is unbounded there by construction, which is why `write(_:from:to:
///   ceiling:)` below replaces it rather than wrapping it.
///
/// `ceiling` deliberately has no default value: a new call site cannot inherit
/// an unbounded extraction by omission, because it will not compile until it
/// states a budget.
///
/// This lives beside the codec rather than in `Shared/` because the widget
/// extension compiles `Shared/` without linking ZIPFoundation, and widening
/// that would need a project-file edit. The remaining `Archive.extract` callers
/// outside Article Workshop (the EPUB, APKG, and ABS importers) still carry
/// their own declared-size checks and should be migrated onto this type; that
/// is tracked as a follow-up rather than done here to keep Task 16 scoped.
///
/// Both entry points also verify the inflated bytes against the entry's
/// declared CRC32, which ZIPFoundation computes but neither `extract` overload
/// compares. A corrupted stream therefore fails as `checksumMismatch` instead
/// of surfacing later as a confusing schema or content-hash error.
nonisolated enum BoundedArchiveExtraction {
    enum Failure: Swift.Error, Equatable {
        /// Inflated output reached the ceiling. The extraction was abandoned
        /// with the remaining compressed bytes unread and unwritten.
        case outputExceededCeiling
        /// The inflated bytes did not match the entry's declared CRC32.
        case checksumMismatch
    }

    /// Inflates `entry` into memory, never accumulating more than
    /// `min(entry.uncompressedSize, ceiling)` bytes.
    static func data(
        _ entry: Entry,
        from archive: Archive,
        ceiling: UInt64
    ) throws -> Data {
        var buffer = Data()
        _ = try stream(entry, from: archive, ceiling: ceiling) { chunk in
            buffer.append(chunk)
        }
        return buffer
    }

    /// Inflates `entry` to `destination`, never writing more than
    /// `min(entry.uncompressedSize, ceiling)` bytes, and returns the number of
    /// bytes actually written so callers can debit a cumulative budget with a
    /// measured figure rather than a declared one.
    ///
    /// A partially written file is removed if the extraction is abandoned, so a
    /// rejected entry leaves nothing behind for a later stage to observe.
    @discardableResult
    static func write(
        _ entry: Entry,
        from archive: Archive,
        to destination: URL,
        ceiling: UInt64
    ) throws -> UInt64 {
        guard
            FileManager.default.createFile(
                atPath: destination.path,
                contents: nil)
        else {
            throw CocoaError(
                .fileWriteUnknown,
                userInfo: [NSFilePathErrorKey: destination.path])
        }
        let handle = try FileHandle(forWritingTo: destination)
        do {
            let written = try stream(entry, from: archive, ceiling: ceiling) {
                chunk in
                try handle.write(contentsOf: chunk)
            }
            try handle.close()
            return written
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Single enforcement point. Everything above funnels through here, so the
    /// invariant is stated once and cannot be forgotten by a new overload.
    private static func stream(
        _ entry: Entry,
        from archive: Archive,
        ceiling: UInt64,
        consume: (Data) throws -> Void
    ) throws -> UInt64 {
        let budget = min(entry.uncompressedSize, ceiling)
        var produced: UInt64 = 0
        let checksum = try archive.extract(entry, skipCRC32: false) { chunk in
            // `budget - produced` cannot underflow: `produced` only ever grows
            // by an amount this guard has already proven fits within it.
            guard UInt64(chunk.count) <= budget - produced else {
                throw Failure.outputExceededCeiling
            }
            produced &+= UInt64(chunk.count)
            try consume(chunk)
        }
        guard checksum == entry.checksum else {
            throw Failure.checksumMismatch
        }
        return produced
    }
}
