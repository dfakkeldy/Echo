import AVFoundation
import Foundation

/// Analyzes raw audio samples to find the end of the most recent silence block
/// before a given timestamp. Used to locate natural breakpoints when the user
/// freezes the timeline during playback.
///
/// All heavy I/O runs off the main thread via Swift Concurrency.
actor SilenceAnalyzer {

    // MARK: - Constants

    /// RMS amplitude threshold in dBFS. Windows below this are considered silence.
    /// -40 dBFS sits well below typical speech (-20 to -10 dBFS) and well above
    /// typical noise floors (-60 to -50 dBFS), so it reliably discriminates
    /// intentional pauses from ambient room tone.
    static let silenceThresholdDB: Float = -40.0

    /// Minimum continuous silence required to qualify as a breakpoint.
    /// 0.4 s filters out brief sentence-internal pauses (0.1–0.3 s) while
    /// catching paragraph and chapter breaks.
    static let minSilenceDuration: TimeInterval = 0.4

    /// Width of each RMS analysis window. 50 ms gives ~20 Hz temporal resolution
    /// (one measurement every ~50 ms) with enough samples per window for a
    /// stable RMS estimate even at low sample rates like 22 050 Hz.
    static let analysisWindowDuration: TimeInterval = 0.05

    // MARK: - Public API

    /// Scans backward from `targetTime` within the given asset and returns the
    /// timestamp where the last qualifying silence block ends (i.e., where audio
    /// resumes after a pause).
    ///
    /// - Parameters:
    ///   - asset: The audio asset to analyze.
    ///   - targetTime: The freeze timestamp, in seconds, from which to scan backward.
    ///   - lookbackWindow: Maximum duration, in seconds, to search backward.
    /// - Returns: The timestamp (in seconds) of the silence→sound transition, or
    ///   `targetTime` if no qualifying silence is found within the window.
    func findLastSilenceEnd(
        in asset: AVAsset,
        targetTime: TimeInterval,
        lookbackWindow: TimeInterval
    ) async -> TimeInterval {
        guard lookbackWindow > 0, targetTime > 0 else { return targetTime }

        let startTime = max(0, targetTime - lookbackWindow)
        let duration = targetTime - startTime
        guard duration > Self.analysisWindowDuration else { return targetTime }

        // 1. Load audio track metadata on the current executor.
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let rawDesc = (try? await track.load(.formatDescriptions))?.first
        else { return targetTime }

        let fmtDesc = rawDesc
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc)
        else { return targetTime }

        let sampleRate = asbd.pointee.mSampleRate

        // 2. Read samples on a detached thread so AVAssetReader I/O never blocks
        //    the cooperative thread pool.
        let sampleData = await Task.detached(priority: .userInitiated) {
            Self.readSamplesSync(asset: asset, track: track,
                                 startTime: startTime, duration: duration)
        }.value
        guard let samples = sampleData else { return targetTime }

        // 3. Compute windowed RMS levels.
        let windowFrames = max(1, Int(Self.analysisWindowDuration * sampleRate))
        let minSilenceWindows = max(1, Int(Self.minSilenceDuration / Self.analysisWindowDuration))
        let windows = Self.computeWindowLevels(
            samples: samples,
            sampleRate: sampleRate,
            windowFrames: windowFrames,
            startTime: startTime
        )

        guard windows.count > 1 else { return targetTime }

        // 4. Scan backward through windows to locate the silence-block end.
        return Self.scanBackward(
            windows: windows,
            windowDuration: Self.analysisWindowDuration,
            minSilenceWindows: minSilenceWindows,
            targetTime: targetTime
        )
    }

    // MARK: - Private: Synchronous sample reading (runs on detached thread)

    /// Reads raw Float32 PCM samples from the asset for the given time range.
    /// Must be called from a non-main, non-cooperative thread — it performs
    /// blocking `copyNextSampleBuffer()` calls.
    private nonisolated static func readSamplesSync(
        asset: AVAsset,
        track: AVAssetTrack,
        startTime: TimeInterval,
        duration: TimeInterval
    ) -> [Float]? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)

        let timescale: CMTimeScale = 600
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: startTime, preferredTimescale: timescale),
            duration: CMTime(seconds: duration, preferredTimescale: timescale)
        )

        guard reader.startReading() else { return nil }

        var allSamples: [Float] = []

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let byteLength = CMBlockBufferGetDataLength(blockBuffer)
            let sampleCount = byteLength / MemoryLayout<Float>.size
            guard sampleCount > 0 else { continue }

            var chunk = [Float](repeating: 0, count: sampleCount)
            let status = chunk.withUnsafeMutableBytes { dest in
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0,
                                           dataLength: byteLength,
                                           destination: dest.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            allSamples.append(contentsOf: chunk)
        }

        return allSamples.isEmpty ? nil : allSamples
    }

    // MARK: - Private: RMS windowing

    private struct WindowLevel {
        let timestamp: TimeInterval  // start of this window, in seconds
        let db: Float                // RMS level in dBFS
    }

    /// Divides interleaved Float32 PCM samples into fixed-duration windows and
    /// computes the RMS level in dBFS for each.
    ///
    /// RMS is computed over all channels together, which gives a single energy
    /// measurement per window regardless of channel count.
    private static func computeWindowLevels(
        samples: [Float],
        sampleRate: Double,
        windowFrames: Int,
        startTime: TimeInterval
    ) -> [WindowLevel] {
        let totalFrames = samples.count
        var windows: [WindowLevel] = []
        windows.reserveCapacity(totalFrames / windowFrames + 1)

        var offset = 0
        while offset < totalFrames {
            let remaining = totalFrames - offset
            let framesThisWindow = min(windowFrames, remaining)

            var sumSquares: Float = 0
            for i in offset ..< (offset + framesThisWindow) {
                sumSquares += samples[i] * samples[i]
            }

            let rms = sqrt(sumSquares / Float(framesThisWindow))
            // Floor at -160 dBFS to avoid -inf for digital silence.
            let db: Float = rms > 1e-10 ? 20 * log10(rms) : -160.0

            let timestamp = startTime + Double(offset) / sampleRate
            windows.append(WindowLevel(timestamp: timestamp, db: db))

            offset += windowFrames
        }

        return windows
    }

    // MARK: - Private: Backward scan state machine

    private enum ScanState {
        /// We are scanning backward through a region above the silence threshold.
        case inSound
        /// We are scanning backward through silence; we have recorded a candidate
        /// transition point but haven't yet confirmed the silence is long enough.
        case inSilence(candidateTime: TimeInterval, consecutiveWindows: Int)
        /// We started the scan inside a silent region (targetTime is in silence).
        /// We must skip past this block — its "end" is in the future, not behind us.
        case inInitialSilence(consecutiveWindows: Int)
        /// Minimum silence duration has been met; we are waiting to exit the
        /// silence block (going backward) to confirm the full extent.
        case validSilenceEnd(candidateTime: TimeInterval)
    }

    /// Scans window levels backward from the end and returns the timestamp where
    /// the last qualifying silence block ends, or `targetTime` as a fallback.
    private static func scanBackward(
        windows: [WindowLevel],
        windowDuration: TimeInterval,
        minSilenceWindows: Int,
        targetTime: TimeInterval
    ) -> TimeInterval {
        // Determine the initial state from the window closest to targetTime.
        let lastIsSilent = windows[windows.count - 1].db < silenceThresholdDB

        var state: ScanState = lastIsSilent
            ? .inInitialSilence(consecutiveWindows: 1)
            : .inSound

        for i in stride(from: windows.count - 2, through: 0, by: -1) {
            let isSilent = windows[i].db < silenceThresholdDB

            switch state {
            case .inSound:
                if isSilent {
                    // Transition sound→silence going backward.
                    // This is the silence→sound boundary in forward time — the
                    // "end" of a silence block.
                    let candidateTime = windows[i].timestamp + windowDuration
                    state = .inSilence(candidateTime: candidateTime, consecutiveWindows: 1)
                }

            case .inSilence(let candidateTime, let count):
                if isSilent {
                    let newCount = count + 1
                    if newCount >= minSilenceWindows {
                        state = .validSilenceEnd(candidateTime: candidateTime)
                    } else {
                        state = .inSilence(candidateTime: candidateTime, consecutiveWindows: newCount)
                    }
                } else {
                    // Silence was too short — discard and go back to scanning sound.
                    state = .inSound
                }

            case .inInitialSilence(let count):
                if isSilent {
                    state = .inInitialSilence(consecutiveWindows: count + 1)
                } else {
                    // We were inside a silence block that extends past targetTime.
                    // Its end is in the future, so skip it and start looking for
                    // the *previous* silence block.
                    state = .inSound
                }

            case .validSilenceEnd(let candidateTime):
                if !isSilent {
                    // Exiting the silence block going backward → we've found the
                    // forward-time start of the silence. The candidate is the
                    // forward-time end of the silence — return it.
                    return candidateTime
                }
                // Still inside the confirmed silence; keep scanning.
            }
        }

        // If we ran out of buffer while inside a confirmed silence, the silence
        // extends beyond our lookback window, but the candidate transition is valid.
        if case .validSilenceEnd(let candidateTime) = state {
            return candidateTime
        }

        return targetTime
    }
}
