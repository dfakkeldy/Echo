import Foundation
import Synchronization
import os.log

// MARK: - AudioRingBuffer

/// Lock-free, single-producer single-consumer ring buffer for PCM Float32 audio samples.
///
/// The producer (audio tap callback, real-time thread) writes samples via `write(_:count:)`.
/// The consumer (background queue) reads them via `readAll()`.
///
/// Capacity is rounded up to the next power of two so index wrapping can use a fast bitmask.
final class AudioRingBuffer {
    private let buffer: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let mask: Int

    /// Write index, atomically updated by the producer using Synchronization.Atomic.
    private let head = Atomic<Int32>(0)

    /// Read index, only touched by the consumer.
    private var tail: Int32 = 0

    /// Creates a ring buffer that can hold at least `capacitySeconds` of audio
    /// at the given sample rate.
    ///
    /// - Parameters:
    ///   - capacitySeconds: Minimum audio duration to store.
    ///   - sampleRate: Samples per second (default 16 000 Hz for WhisperKit).
    init(capacitySeconds: TimeInterval, sampleRate: Double = 16_000) {
        let sampleCount = Int(capacitySeconds * sampleRate)
        // Round up to next power of two for efficient masking.
        var pow2 = 1
        while pow2 < sampleCount { pow2 <<= 1 }
        self.capacity = pow2
        self.mask = pow2 - 1
        self.buffer = UnsafeMutablePointer<Float>.allocate(capacity: pow2)
        buffer.initialize(repeating: 0, count: pow2)
    }

    deinit {
        buffer.deallocate()
    }

    // MARK: - Producer (real-time audio thread safe)

    /// Write PCM samples from the real-time audio tap.
    ///
    /// This method does not allocate memory, take locks, or call any OS
    /// function that could block — it is safe to call on the audio thread.
    func write(_ samples: UnsafePointer<Float>, count: Int) {
        if count <= 0 { return }

        // Read head without a barrier; we're the only writer.
        let local = Int(head.load(ordering: .relaxed))
        for i in 0..<count {
            buffer[(local + i) & mask] = samples[i]
        }
        // Publish writes with a release barrier so the consumer sees them.
        head.add(Int32(count), ordering: .releasing)
    }

    // MARK: - Consumer (background queue)

    /// Drains all unread samples into a `[Float]` array.
    ///
    /// Must NOT be called from the real-time audio thread.
    func readAll() -> [Float] {
        let h = Int(head.load(ordering: .acquiring))
        let available = h - Int(tail)
        guard available > 0 else { return [] }

        var result = [Float](repeating: 0, count: available)
        let t = Int(tail)
        for i in 0..<available {
            result[i] = buffer[(t + i) & mask]
        }
        tail = Int32(t + available)
        return result
    }

    /// Returns the number of unread samples without consuming them.
    var availableSampleCount: Int {
        let h = Int(head.load(ordering: .acquiring))
        return h - Int(tail)
    }

    /// Discard any buffered samples (consumer-side only).
    func reset() {
        tail = Int32(head.load(ordering: .acquiring))
    }
}
