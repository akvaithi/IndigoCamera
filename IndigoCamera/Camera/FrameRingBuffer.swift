import CoreMedia
import os

/// Thread-safe circular buffer holding the most recent N frames
/// for zero-shutter-lag capture. Frames are CMSampleBuffers from
/// the continuous video data output.
final class FrameRingBuffer {
    private let capacity: Int
    private var buffer: [CMSampleBuffer?]
    private var writeIndex: Int = 0
    private var count: Int = 0
    private let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)

    init(capacity: Int = 16) {
        self.capacity = capacity
        self.buffer = Array(repeating: nil, count: capacity)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// Add a new frame. If the buffer is full, the oldest frame is overwritten.
    func append(_ sampleBuffer: CMSampleBuffer) {
        os_unfair_lock_lock(lock)
        buffer[writeIndex] = sampleBuffer
        writeIndex = (writeIndex + 1) % capacity
        count = min(count + 1, capacity)
        os_unfair_lock_unlock(lock)
    }

    /// Snapshot the most recent `requestedCount` frames in chronological order (oldest first).
    /// The reference frame (most recent) will be the last element.
    func snapshot(count requestedCount: Int) -> [CMSampleBuffer] {
        os_unfair_lock_lock(lock)
        let available = min(requestedCount, count)
        var result: [CMSampleBuffer] = []
        result.reserveCapacity(available)

        let startIndex = (writeIndex - available + capacity) % capacity
        for i in 0..<available {
            let idx = (startIndex + i) % capacity
            if let frame = buffer[idx] {
                result.append(frame)
            }
        }
        os_unfair_lock_unlock(lock)
        return result
    }

    /// Clear all frames to free memory (e.g., after processing or on memory warning).
    func clear() {
        os_unfair_lock_lock(lock)
        for i in 0..<capacity {
            buffer[i] = nil
        }
        count = 0
        writeIndex = 0
        os_unfair_lock_unlock(lock)
    }

    /// Current number of frames stored.
    var currentCount: Int {
        os_unfair_lock_lock(lock)
        let c = count
        os_unfair_lock_unlock(lock)
        return c
    }

    /// Maximum safe frame count given current available memory and capture mode.
    static func maxSafeFrameCount(for mode: CaptureMode) -> Int {
        let availableMemory = os_proc_available_memory()
        let perFrameBytes: Int = 4032 * 3024 * 4  // ~49 MB for BGRA

        let processingOverhead: Int
        switch mode {
        case .quick:
            processingOverhead = 100_000_000       // ~100 MB
        case .stack:
            processingOverhead = 500_000_000       // ~500 MB for accumulators + working textures
        case .superRes:
            processingOverhead = 900_000_000       // ~900 MB for high-res accumulators + reference
        }

        let safetyMargin = 200_000_000             // ~200 MB buffer
        let available = Int(availableMemory) - processingOverhead - safetyMargin
        return max(2, min(16, available / perFrameBytes))
    }

    /// Maximum safe frame count (default: stack mode).
    static var maxSafeFrameCount: Int {
        maxSafeFrameCount(for: .stack)
    }
}
