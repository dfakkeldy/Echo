// SPDX-License-Identifier: GPL-3.0-or-later
//
//  MacAudioBoostTap.swift
//  Echo macOS
//
//  Installs an MTAudioProcessingTap on an AVPlayerItem's audio track to apply a
//  linear gain multiplier (volume boost above unity, which AVAudioMix volume
//  cannot do). The gain is read live from a shared box so toggling boost does
//  not require rebuilding the tap.
//
import AVFoundation
import Foundation
import os.log

/// Reference-type holder for the current linear gain, shared between the
/// MainActor model and the real-time audio process callback. `gain` is a plain
/// Float; the audio callback reads it without locking (a torn read of a Float
/// is benign here — at worst one buffer uses a slightly stale multiplier).
final class MacVolumeBoostGainBox: @unchecked Sendable {
    var gain: Float = 1.0
    /// Set by the tap's `prepare` callback once the processing format is known.
    /// Defaults to `false` so the process callback no-ops (clean passthrough)
    /// until prepare confirms the route is non-interleaved 32-bit float PCM —
    /// the only layout the sample loop is safe to multiply in place.
    var formatSupported: Bool = false
}

enum MacAudioBoostTap {

    /// Builds an `AVAudioMix` that applies a live linear gain to the first audio
    /// track of `item` via an MTAudioProcessingTap. Returns nil if the item has
    /// no audio track or the tap cannot be created.
    static func makeAudioMix(for item: AVPlayerItem, gainBox: MacVolumeBoostGainBox) -> AVAudioMix?
    {
        guard let track = item.tracks.compactMap(\.assetTrack).first(where: {
            $0.mediaType == .audio
        }) else { return nil }

        // Hand a +1 retained reference to the C clientInfo. `tapFinalize` balances
        // it when the tap is deallocated — but only for a tap that was actually
        // created, so keep the retained handle to release on the failure path below.
        let retainedBox = Unmanaged.passRetained(gainBox)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(retainedBox.toOpaque()),
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: nil,
            process: tapProcess
        )

        // On macOS 15+/26 the Swift overlay surfaces the +1 out-parameter as a
        // managed `MTAudioProcessingTap?` (not `Unmanaged<…>`), so ARC owns it
        // and we assign it directly to `audioTapProcessor` — no manual
        // `takeRetainedValue()`.
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &tap
        )
        guard status == noErr, let unwrapped = tap else {
            // `tapFinalize` never runs for a tap that failed to create, so balance
            // the +1 we handed to `clientInfo` here to avoid leaking the gain box.
            retainedBox.release()
            Logger(category: "MacAudioBoostTap").error(
                "MTAudioProcessingTapCreate failed: \(status)")
            return nil
        }

        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = unwrapped

        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }

    // MARK: - Tap C callbacks

    private static let tapInit: MTAudioProcessingTapInitCallback = {
        (tap, clientInfo, tapStorageOut) in
        tapStorageOut.pointee = clientInfo
    }

    private static let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
        let storage = MTAudioProcessingTapGetStorage(tap)
        Unmanaged<MacVolumeBoostGainBox>.fromOpaque(storage).release()
    }

    /// Invoked when the audio machinery is (re)initialized, before any process
    /// call. We inspect the processing format and only allow the boost when it is
    /// linear-PCM float — the sample loop multiplies `Float` samples in place, so
    /// a non-float (e.g. integer) route would otherwise be reinterpreted as float
    /// and emit noise. Recording the result here lets `tapProcess` degrade to a
    /// clean passthrough (no boost) instead of corrupting samples.
    private static let tapPrepare: MTAudioProcessingTapPrepareCallback = {
        (tap, _, processingFormat) in
        let storage = MTAudioProcessingTapGetStorage(tap)
        let box = Unmanaged<MacVolumeBoostGainBox>.fromOpaque(storage).takeUnretainedValue()
        let asbd = processingFormat.pointee
        box.formatSupported =
            (asbd.mFormatID == kAudioFormatLinearPCM)
            && ((asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0)
    }

    private static let tapProcess: MTAudioProcessingTapProcessCallback = {
        (tap, numberFrames, flags, bufferListInOut, numberFramesOut, flagsOut) in

        let status = MTAudioProcessingTapGetSourceAudio(
            tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
        guard status == noErr else { return }

        let storage = MTAudioProcessingTapGetStorage(tap)
        let box = Unmanaged<MacVolumeBoostGainBox>.fromOpaque(storage).takeUnretainedValue()
        let gain = box.gain
        // `formatSupported` is set by `tapPrepare`: a non-float / non-PCM route
        // skips the loop entirely, degrading to no boost (clean passthrough)
        // rather than reinterpreting raw bytes as Float and corrupting samples.
        guard box.formatSupported, gain != 1.0 else { return }

        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListInOut)
        for buffer in bufferList {
            guard let raw = buffer.mData else { continue }
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let samples = raw.assumingMemoryBound(to: Float.self)
            for i in 0..<sampleCount {
                samples[i] *= gain
            }
        }
    }
}
