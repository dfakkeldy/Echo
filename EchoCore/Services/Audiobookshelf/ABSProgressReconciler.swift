// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Pure last-write-wins conflict resolution between local playback progress and ABS's.
/// Timestamps are epoch ms. ABS is authoritative on a tie / when there is no local stamp.
enum ABSProgressDecision: Equatable {
    case seekLocalTo(Double)  // remote newer & meaningfully different — move the local playhead
    case pushLocal  // local newer (or no remote) — push local to ABS
    case noop  // already in sync
}

enum ABSProgressReconciler {
    static func decide(
        localTime: Double,
        localUpdatedAt: Double?,
        remoteTime: Double?,
        remoteUpdatedAt: Double?,
        thresholdSeconds: Double = 5
    ) -> ABSProgressDecision {
        guard let remoteTime, let remoteUpdatedAt else { return .pushLocal }  // no remote → push
        guard let localUpdatedAt else {  // no local stamp → trust remote
            return abs(remoteTime - localTime) > thresholdSeconds ? .seekLocalTo(remoteTime) : .noop
        }
        if remoteUpdatedAt > localUpdatedAt {
            return abs(remoteTime - localTime) > thresholdSeconds ? .seekLocalTo(remoteTime) : .noop
        }
        if localUpdatedAt > remoteUpdatedAt { return .pushLocal }
        return .noop
    }
}
