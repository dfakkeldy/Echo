/// Port of ``_build_alignment_matrix`` from ``kokoro/coreml_pipeline.py:336-362``.
///
/// Constructs a one-hot alignment matrix ``(traceLength, frameCount)`` from
/// predicted phoneme durations. Each column is a one-hot vector indicating
/// which token that frame belongs to.
///
/// Used to align duration-domain features to frame-domain features via
/// matrix multiplication: ``en = d @ alignment``, ``asr = t_en @ alignment``.

import Foundation

/// Build a one-hot alignment matrix from predicted phoneme durations.
///
/// - Parameters:
///   - predDur: Per-token durations in frames, length <= traceLength.
///   - traceLength: Number of tokens (rows in output matrix).
///   - frameCount: Number of frames (columns in output matrix).
/// - Returns: Flat Float array of shape (traceLength, frameCount) in row-major order.
///
/// Reference: ``kokoro/coreml_pipeline.py:336-362``
public func buildAlignmentMatrix(
    predDur: [Int],
    traceLength: Int,
    frameCount: Int
) -> [Float] {
    precondition(traceLength >= 1 && frameCount >= 1)

    // Pad or truncate token durations to traceLength
    var dur = [Int](repeating: 0, count: traceLength)
    let copyLen = min(traceLength, predDur.count)
    for i in 0..<copyLen {
        dur[i] = predDur[i]
    }

    // Build repeat index: repeat each token index by its duration
    var repeatIdx = [Int]()
    repeatIdx.reserveCapacity(frameCount)
    for (tokenIdx, count) in dur.enumerated() {
        for _ in 0..<count {
            repeatIdx.append(tokenIdx)
        }
    }

    // Truncate or pad to frameCount
    if repeatIdx.count > frameCount {
        repeatIdx = Array(repeatIdx.prefix(frameCount))
    } else if repeatIdx.count < frameCount {
        let lastIdx = repeatIdx.last.map { min($0, traceLength - 1) } ?? 0
        let pad = frameCount - repeatIdx.count
        repeatIdx.append(contentsOf: [Int](repeating: lastIdx, count: pad))
    }

    // Clamp indices
    for i in 0..<repeatIdx.count {
        repeatIdx[i] = max(0, min(repeatIdx[i], traceLength - 1))
    }

    // Build one-hot matrix: mat[repeatIdx[frame], frame] = 1.0
    var mat = [Float](repeating: 0, count: traceLength * frameCount)
    for frame in 0..<frameCount {
        let row = repeatIdx[frame]
        mat[row * frameCount + frame] = 1.0
    }

    return mat
}
