import Foundation

/// Filters `TokenDTW.AnchorCandidate`s down to the set worth persisting as
/// alignment anchors.
///
/// Two rules:
/// 1. **Confidence gate** — a candidate must sit inside a strong-match run of
///    at least `minRunLength` tokens. This is what keeps never-narrated text
///    (front matter, mis-binned boundary blocks, Whisper hallucinations) from
///    anchoring: isolated lucky word matches don't form runs.
/// 2. **Monotonicity** — anchors must be non-decreasing in time along the
///    block reading order. On a violation the weaker run is dropped, so one
///    bad match can't fold the timeline back on itself.
enum AnchorSelector {

    /// - Parameter candidates: Candidates in **block reading order**
    ///   (sequence-index order), at most one per block.
    static func select(
        candidates: [TokenDTW.AnchorCandidate],
        minRunLength: Int = 3
    ) -> [TokenDTW.AnchorCandidate] {
        let epsilon: TimeInterval = 0.25
        var kept: [TokenDTW.AnchorCandidate] = []

        for candidate in candidates where candidate.exactRunLength >= minRunLength {
            // A candidate earlier in time than its predecessors is a
            // conflict: evict strictly weaker predecessors, otherwise drop
            // the newcomer.
            while let last = kept.last,
                  candidate.time + epsilon < last.time,
                  candidate.exactRunLength > last.exactRunLength {
                kept.removeLast()
            }
            if let last = kept.last, candidate.time + epsilon < last.time {
                continue
            }
            kept.append(candidate)
        }
        return kept
    }
}
