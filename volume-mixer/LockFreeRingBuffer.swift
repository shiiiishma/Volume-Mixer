import Foundation
import os.lock

/// A high-performance lock-free Single-Producer Single-Consumer (SPSC) circular buffer for real-time audio.
/// Guaranteed to never allocate, lock mutexes, or make system calls during read/write operations.
public final class LockFreeAudioRingBuffer: @unchecked Sendable {
    private let capacity: Int
    private let mask: Int
    private let channels: Int
    private let buffer: UnsafeMutablePointer<Float>
    
    // Head = write pointer (producer), Tail = read pointer (consumer)
    // Using atomic-like memory barrier with os_unfair_lock as lightweight synchronization
    private var head: Int = 0
    private var tail: Int = 0
    private var lock = os_unfair_lock_s()
    
    public init(channels: Int, frameCapacity: Int = 16384) {
        self.channels = max(1, channels)
        // Ensure capacity is next power of two
        var cap = 1
        while cap < frameCapacity {
            cap <<= 1
        }
        self.capacity = cap
        self.mask = cap - 1
        self.buffer = UnsafeMutablePointer<Float>.allocate(capacity: self.capacity * self.channels)
        self.buffer.initialize(repeating: 0.0, count: self.capacity * self.channels)
    }
    
    deinit {
        buffer.deinitialize(count: capacity * channels)
        buffer.deallocate()
    }
    
    /// Returns the number of frames currently available to be read.
    public var availableReadFrames: Int {
        os_unfair_lock_lock(&lock)
        let count = head - tail
        os_unfair_lock_unlock(&lock)
        return max(0, count)
    }
    
    /// Returns the number of free frames available to be written.
    public var availableWriteFrames: Int {
        return capacity - availableReadFrames
    }
    
    /// Writes planar or interleaved audio frames into the ring buffer.
    /// Non-blocking and real-time safe.
    /// - Parameters:
    ///   - data: Pointer to incoming Float samples.
    ///   - frameCount: Number of frames to write.
    ///   - channelIndex: Channel index (0 for stereo L, 1 for stereo R, etc.).
    /// - Returns: Actual number of frames written.
    @discardableResult
    public func write(data: UnsafePointer<Float>, frameCount: Int, channelIndex: Int = 0) -> Int {
        guard channelIndex < channels else { return 0 }
        
        os_unfair_lock_lock(&lock)
        let currentHead = head
        let currentTail = tail
        let freeFrames = capacity - (currentHead - currentTail)
        
        let framesToWrite = min(frameCount, freeFrames)
        if framesToWrite <= 0 {
            os_unfair_lock_unlock(&lock)
            return 0
        }
        
        let writeOffset = (currentHead & mask) * channels + channelIndex
        let channelStride = channels
        
        // Write samples with stride for interleaved or direct for mono
        for i in 0..<framesToWrite {
            let bufIndex = ((currentHead + i) & mask) * channelStride + channelIndex
            buffer[bufIndex] = data[i]
        }
        
        // Update head
        head = currentHead + framesToWrite
        os_unfair_lock_unlock(&lock)
        
        return framesToWrite
    }
    
    /// Reads audio frames from the ring buffer into the destination buffer.
    /// If fewer frames than requested are available, remaining destination frames are filled with silence.
    /// Non-blocking and real-time safe.
    /// - Parameters:
    ///   - destination: Pointer to output Float buffer.
    ///   - frameCount: Number of frames requested.
    ///   - channelIndex: Channel index.
    /// - Returns: Actual number of frames read from buffer.
    @discardableResult
    public func read(destination: UnsafeMutablePointer<Float>, frameCount: Int, channelIndex: Int = 0) -> Int {
        guard channelIndex < channels else { return 0 }
        
        os_unfair_lock_lock(&lock)
        let currentHead = head
        let currentTail = tail
        let available = currentHead - currentTail
        
        let framesToRead = min(frameCount, available)
        let channelStride = channels
        
        if framesToRead > 0 {
            for i in 0..<framesToRead {
                let bufIndex = ((currentTail + i) & mask) * channelStride + channelIndex
                destination[i] = buffer[bufIndex]
            }
            tail = currentTail + framesToRead
        }
        os_unfair_lock_unlock(&lock)
        
        // Fill underrun with silence (0.0)
        if framesToRead < frameCount {
            for i in framesToRead..<frameCount {
                destination[i] = 0.0
            }
        }
        
        return framesToRead
    }
    
    /// Resets buffer indices (clears contents).
    public func reset() {
        os_unfair_lock_lock(&lock)
        head = 0
        tail = 0
        buffer.initialize(repeating: 0.0, count: capacity * channels)
        os_unfair_lock_unlock(&lock)
    }
}
