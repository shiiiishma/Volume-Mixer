import Foundation
import Accelerate

/// Real-time safe audio gain processor with click-free parameter ramping.
/// Uses Apple's Accelerate framework (vDSP) for vectorized SIMD operations.
public final class GainRampProcessor: @unchecked Sendable {
    private var currentGain: Float
    private var targetGain: Float
    private let defaultRampDurationFrames: Int
    
    // Scratch buffer for ramp multiplier generation, pre-allocated to avoid heap allocations
    private let maxRampFrames: Int = 1024
    private let rampBuffer: UnsafeMutablePointer<Float>
    
    public init(initialGain: Float = 1.0, rampFrames: Int = 128) {
        self.currentGain = initialGain
        self.targetGain = initialGain
        self.defaultRampDurationFrames = min(rampFrames, 1024)
        self.rampBuffer = UnsafeMutablePointer<Float>.allocate(capacity: 1024)
        self.rampBuffer.initialize(repeating: 1.0, count: 1024)
    }
    
    deinit {
        rampBuffer.deinitialize(count: 1024)
        rampBuffer.deallocate()
    }
    
    /// Sets a new target gain. Gain will smoothly ramp towards this value over subsequent audio buffers.
    /// Real-time safe (atomic float assignment on 64-bit architecture).
    public func setTargetGain(_ newTarget: Float) {
        self.targetGain = max(0.0, min(1.0, newTarget))
    }
    
    /// Immediate gain update without ramping (e.g. for initialization).
    public func resetGain(_ newGain: Float) {
        let clamped = max(0.0, min(1.0, newGain))
        self.currentGain = clamped
        self.targetGain = clamped
    }
    
    /// Processes incoming samples and applies gain with smooth ramping.
    /// - Parameters:
    ///   - input: Pointer to source Float samples.
    ///   - output: Pointer to destination Float samples.
    ///   - frameCount: Number of sample frames.
    public func process(
        input: UnsafePointer<Float>,
        output: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        guard frameCount > 0 else { return }
        
        // Check if gain is in steady-state (no active ramp)
        if abs(currentGain - targetGain) < 0.0001 {
            currentGain = targetGain
            
            if currentGain == 0.0 {
                // Muted: clear buffer to zero
                vDSP_vclr(output, 1, vDSP_Length(frameCount))
            } else if currentGain == 1.0 {
                // Unity gain: copy buffer
                memcpy(output, input, frameCount * MemoryLayout<Float>.size)
            } else {
                // Constant gain scaling
                var gain = currentGain
                vDSP_vsmul(input, 1, &gain, output, 1, vDSP_Length(frameCount))
            }
            return
        }
        
        // Active ramp required
        let rampLength = min(frameCount, defaultRampDurationFrames)
        let gainDelta = targetGain - currentGain
        var start = currentGain
        var step = gainDelta / Float(rampLength)
        
        // Generate linear ramp multipliers: rampBuffer[i] = start + i * step
        vDSP_vramp(&start, &step, rampBuffer, 1, vDSP_Length(rampLength))
        
        // Apply ramp multipliers to the initial chunk
        vDSP_vmul(input, 1, rampBuffer, 1, output, 1, vDSP_Length(rampLength))
        
        // Update current gain after the ramp chunk
        currentGain = targetGain
        
        // Process remaining frames in this buffer at steady targetGain
        let remaining = frameCount - rampLength
        if remaining > 0 {
            let inPtr = input.advanced(by: rampLength)
            let outPtr = output.advanced(by: rampLength)
            
            if currentGain == 0.0 {
                vDSP_vclr(outPtr, 1, vDSP_Length(remaining))
            } else if currentGain == 1.0 {
                memcpy(outPtr, inPtr, remaining * MemoryLayout<Float>.size)
            } else {
                var gain = currentGain
                vDSP_vsmul(inPtr, 1, &gain, outPtr, 1, vDSP_Length(remaining))
            }
        }
    }
}
