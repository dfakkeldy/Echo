/// Port of ``_select_bucket_seconds`` from ``kokoro/coreml_pipeline.py:319-334``.
///
/// Picks the smallest available bucket duration (in seconds) that is >= the
/// requested duration. Falls back to the largest bucket if none is large enough.
///
/// Contract: bucket >= ceil(total_seconds).

import Foundation

/// Select the appropriate bucket for a given audio duration.
///
/// - Parameters:
///   - totalSeconds: Estimated audio duration in seconds (from F0 frames / 80.0).
///   - availableBuckets: Sorted list of available bucket durations in seconds.
/// - Returns: The selected bucket duration, or nil if no buckets available.
public func selectBucket(totalSeconds: Double, availableBuckets: [Int]) -> Int? {
    guard !availableBuckets.isEmpty else { return nil }
    let sorted = availableBuckets.sorted()
    let threshold = Int(ceil(totalSeconds))
    for sec in sorted {
        if sec >= threshold {
            return sec
        }
    }
    // Fallback to largest bucket
    return sorted.last
}
