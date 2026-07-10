// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Formats `HeadlessNarrationRunner` progress events into the human-readable
/// stderr lines `echo-cli narrate` prints. Pure + platform-neutral so the unit
/// tests can pin the exact strings overnight agents grep, and so the CLI can
/// dedupe on `message` (the timestamp changes every event; the message only
/// changes when something actually advanced).
enum NarrationRunProgressFormatter {

    /// The stable, timestamp-free description of a progress event. Callers
    /// dedupe consecutive identical messages to keep logs readable.
    static func message(for progress: NarrationRunProgress) -> String {
        switch progress {
        case .importing:
            return "importing source"
        case .preparing(let fraction):
            return "preparing voice models \(percent(fraction))%"
        case .chapter(let index, let of, let fraction):
            let displayChapter = of == 0 ? 0 : min(index + 1, of)
            return "chapter \(displayChapter)/\(of) · \(percent(fraction))% of batch"
        case .exporting:
            return "exporting m4b"
        case .wroteSidecar(let anchors, let anchorsWithWords):
            return "sidecar written (\(anchors) anchors, \(anchorsWithWords) with word timings)"
        }
    }

    /// A full log line: `[m:ss] message`.
    static func line(for progress: NarrationRunProgress, elapsed: TimeInterval) -> String {
        "[\(timestamp(elapsed))] \(message(for: progress))"
    }

    /// Elapsed wall time as `m:ss` (hours roll into minutes: `75:02`), so an
    /// agent reading a log can spot a stall or a 10× regression at a glance.
    static func timestamp(_ elapsed: TimeInterval) -> String {
        let total = max(0, Int(elapsed.rounded()))
        let minutes = total / 60
        let seconds = total % 60
        return "\(minutes):\(seconds < 10 ? "0" : "")\(seconds)"
    }

    /// Final summary suffix: audio seconds rendered, wall seconds spent, and
    /// the realtime factor — exactly what's needed to notice an accidental
    /// Debug (-Onone) binary in an overnight log.
    static func summary(audioSeconds: Double, wallSeconds: Double) -> String {
        let audio = Int(audioSeconds.rounded())
        let wall = max(1, Int(wallSeconds.rounded()))
        let speed = audioSeconds / Double(wall)
        let factor = speed.formatted(.number.precision(.fractionLength(1)))
        return "\(audio)s audio in \(wall)s wall (\(factor)× realtime)"
    }

    private static func percent(_ fraction: Double) -> Int {
        Int((min(max(fraction, 0), 1) * 100).rounded())
    }
}
