import Accelerate
import AVFoundation
import os.log

// MARK: - DefaultVisualizerTap

/// Installs a tap on the engine's main mixer node and provides an
/// `AsyncStream` of audio analysis frames containing RMS, peak, and
/// a 16-bin power spectrum at ~30 fps (default).
///
/// - Important: The tap callback runs on a real-time audio thread.
///   Work is kept minimal — spectrum computation uses vDSP and any
///   heavy processing should be done by consuming the stream off that
///   thread.
final class DefaultVisualizerTap: VisualizerDataProviding {
    private weak var engine: AVAudioEngine?
    private var continuation: AsyncStream<VisualizerFrame>.Continuation?
    private var isTapInstalled = false

    private let fftSize: Int = 512
    private let numberOfBands: Int = 16
    private let frameInterval: AVAudioFrameCount

    // MARK: - AsyncStream

    var frames: AsyncStream<VisualizerFrame> {
        AsyncStream { [weak self] continuation in
            self?.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                self?.removeTap()
            }
        }
    }

    // MARK: - Init

    init(engine: AVAudioEngine, frameRate: Float = 30) {
        self.engine = engine
        // ~44100 / 30 ≈ 1470 samples per callback
        let sampleRate: Double = 44100
        self.frameInterval = AVAudioFrameCount(sampleRate / Double(frameRate))
        installTap()
    }

    // MARK: - Tap Management

    private func installTap() {
        guard let engine, !isTapInstalled else { return }
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        let bufferSize = frameInterval

        engine.mainMixerNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            guard let self, let channelData = buffer.floatChannelData else { return }
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }

            let samples = UnsafeBufferPointer(start: channelData[0], count: frameLength)
            let frame = self.analyze(samples: Array(samples), frameLength: frameLength)
            self.continuation?.yield(frame)
        }

        isTapInstalled = true
    }

    private func removeTap() {
        guard isTapInstalled else { return }
        engine?.mainMixerNode.removeTap(onBus: 0)
        isTapInstalled = false
    }

    // MARK: - Analysis

    private func analyze(samples: [Float], frameLength: Int) -> VisualizerFrame {
        let count = min(frameLength, samples.count)
        guard count > 0 else {
            return VisualizerFrame(rms: 0, peak: 0, spectrum: Array(repeating: 0, count: numberOfBands), timestamp: CACurrentMediaTime())
        }

        // --- RMS ---
        var sumSquares: Float = 0
        vDSP_svesq(samples, 1, &sumSquares, vDSP_Length(count))
        let rms = sqrt(sumSquares / Float(count))

        // --- Peak ---
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(count))

        // --- Spectrum (FFT-based, 16 bands) ---
        let spectrum: [Float]
        if count >= fftSize {
            spectrum = computeSpectrum(samples: Array(samples.prefix(fftSize)), bands: numberOfBands)
        } else {
            // Pad with zeros if we have fewer samples than fftSize
            var padded = samples
            padded.append(contentsOf: [Float](repeating: 0, count: fftSize - count))
            spectrum = computeSpectrum(samples: padded, bands: numberOfBands)
        }

        return VisualizerFrame(rms: rms, peak: peak, spectrum: spectrum, timestamp: CACurrentMediaTime())
    }

    /// Compute a power spectrum via vDSP forward FFT and bin the
    /// result into `bands` frequency bins.
    private func computeSpectrum(samples: [Float], bands: Int) -> [Float] {
        let n = samples.count
        let log2n = vDSP_Length(log2(Float(n)))

        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return fallbackSpectrum(samples: samples, bands: bands)
        }

        // Prepare split-complex buffers.
        var realp = [Float](repeating: 0, count: n / 2)
        var imagp = [Float](repeating: 0, count: n / 2)
        var splitComplex = DSPSplitComplex(realp: &realp, imagp: &imagp)

        // Pack real samples into split-complex (odd-index = imag, even = real).
        samples.withUnsafeBytes { src in
            vDSP_ctoz(
                src.bindMemory(to: DSPComplex.self).baseAddress!, 2,
                &splitComplex, 1,
                vDSP_Length(n / 2)
            )
        }

        // Forward FFT.
        vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))

        // Compute magnitudes (|Re|² + |Im|²).
        var magnitudes = [Float](repeating: 0, count: n / 2)
        vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(n / 2))

        // Convert to dB: 20 * log10(magnitude) with floor at 1e-10.
        var one: Float = 1
        var clipMin: Float = 1e-10
        vDSP_vdbcon(magnitudes, 1, &one, &magnitudes, 1, vDSP_Length(n / 2), 0)
        vDSP_vthr(magnitudes, 1, &clipMin, &magnitudes, 1, vDSP_Length(n / 2))

        vDSP_destroy_fftsetup(fftSetup)

        // Bin into `bands` frequency bins.
        return binMagnitudes(magnitudes, bands: bands)
    }

    private func binMagnitudes(_ magnitudes: [Float], bands: Int) -> [Float] {
        let halfN = magnitudes.count
        let binsPerBand = max(1, halfN / bands)
        var spectrum = [Float](repeating: 0, count: bands)

        for band in 0..<bands {
            let start = band * binsPerBand
            let end = min(start + binsPerBand, halfN)
            guard end > start else { continue }

            var sum: Float = 0
            for i in start..<end {
                sum += magnitudes[i]
            }
            spectrum[band] = sum / Float(end - start)
        }

        return spectrum
    }

    /// Fallback: compute binned magnitudes without an FFT setup
    /// by applying a crude DFT at representative frequencies.
    private func fallbackSpectrum(samples: [Float], bands: Int) -> [Float] {
        let n = samples.count
        guard n > 0 else { return Array(repeating: 0, count: bands) }

        var spectrum = [Float](repeating: 0, count: bands)
        for band in 0..<bands {
            // Centre frequency for this band: linearly spaced in 0..<n/2
            let centreBin = (band + 1) * (n / 2) / bands
            let omega = 2 * Float.pi * Float(centreBin) / Float(n)
            var real: Float = 0
            var imag: Float = 0
            for i in 0..<n {
                let angle = omega * Float(i)
                real += samples[i] * cos(angle)
                imag += samples[i] * sin(angle)
            }
            spectrum[band] = sqrt(real * real + imag * imag) / Float(n)
        }
        return spectrum
    }

    deinit {
        removeTap()
    }
}
