import Testing
import Accelerate
import Foundation

// MARK: - Standalone DSP Core for Testing

fileprivate final class TestRingBuffer {
    private let channels: Int
    private let capacity: Int
    private let indexMask: Int
    private var writeIndices: [Int]
    private var readIndices: [Int]
    private var buffers: [UnsafeMutablePointer<Float>]
    
    init(channels: Int, frameCapacity: Int) {
        self.channels = channels
        var cap = 1
        while cap < frameCapacity { cap <<= 1 }
        self.capacity = cap
        self.indexMask = cap - 1
        self.writeIndices = Array(repeating: 0, count: channels)
        self.readIndices = Array(repeating: 0, count: channels)
        self.buffers = (0..<channels).map { _ in
            UnsafeMutablePointer<Float>.allocate(capacity: cap)
        }
    }
    
    deinit {
        for buf in buffers {
            buf.deallocate()
        }
    }
    
    var availableReadFrames: Int {
        return (writeIndices[0] - readIndices[0]) & indexMask
    }
    
    var availableWriteFrames: Int {
        return capacity - 1 - availableReadFrames
    }
    
    func write(data: UnsafePointer<Float>, frameCount: Int, channelIndex: Int = 0) -> Int {
        let toWrite = min(frameCount, availableWriteFrames)
        guard toWrite > 0 else { return 0 }
        
        let writeIdx = writeIndices[channelIndex]
        let buffer = buffers[channelIndex]
        let endIdx = (writeIdx + toWrite) & indexMask
        
        if endIdx > writeIdx {
            buffer.advanced(by: writeIdx).assign(from: data, count: toWrite)
        } else {
            let firstPart = capacity - writeIdx
            buffer.advanced(by: writeIdx).assign(from: data, count: firstPart)
            let secondPart = toWrite - firstPart
            if secondPart > 0 {
                buffer.assign(from: data.advanced(by: firstPart), count: secondPart)
            }
        }
        
        writeIndices[channelIndex] = (writeIdx + toWrite) & indexMask
        return toWrite
    }
    
    func read(destination: UnsafeMutablePointer<Float>, frameCount: Int, channelIndex: Int = 0) -> Int {
        let toRead = min(frameCount, availableReadFrames)
        if toRead <= 0 {
            vDSP_vclr(destination, 1, vDSP_Length(frameCount))
            return 0
        }
        
        let readIdx = readIndices[channelIndex]
        let buffer = buffers[channelIndex]
        let endIdx = (readIdx + toRead) & indexMask
        
        if endIdx > readIdx {
            destination.assign(from: buffer.advanced(by: readIdx), count: toRead)
        } else {
            let firstPart = capacity - readIdx
            destination.assign(from: buffer.advanced(by: readIdx), count: firstPart)
            let secondPart = toRead - firstPart
            if secondPart > 0 {
                destination.advanced(by: firstPart).assign(from: buffer, count: secondPart)
            }
        }
        
        if toRead < frameCount {
            vDSP_vclr(destination.advanced(by: toRead), 1, vDSP_Length(frameCount - toRead))
        }
        
        readIndices[channelIndex] = (readIdx + toRead) & indexMask
        return toRead
    }
}

fileprivate final class TestGainRampProcessor {
    private var currentGain: Float
    private var targetGain: Float
    private let rampFrames: Int
    private var rampBuffer: [Float]
    
    init(initialGain: Float = 1.0, rampFrames: Int = 128) {
        self.currentGain = initialGain
        self.targetGain = initialGain
        self.rampFrames = rampFrames
        self.rampBuffer = Array(repeating: 0.0, count: max(rampFrames, 4096))
    }
    
    func setTargetGain(_ gain: Float) {
        self.targetGain = max(0.0, min(1.0, gain))
    }
    
    func resetGain(_ gain: Float) {
        self.currentGain = max(0.0, min(1.0, gain))
        self.targetGain = self.currentGain
    }
    
    func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount: Int) {
        if abs(currentGain - targetGain) < 0.0001 {
            currentGain = targetGain
            if currentGain == 0.0 {
                vDSP_vclr(output, 1, vDSP_Length(frameCount))
            } else if currentGain == 1.0 {
                output.assign(from: input, count: frameCount)
            } else {
                var gain = currentGain
                vDSP_vsmul(input, 1, &gain, output, 1, vDSP_Length(frameCount))
            }
            return
        }
        
        let framesToRamp = min(frameCount, rampFrames)
        var startGain = currentGain
        var gainStep = (targetGain - currentGain) / Float(rampFrames)
        
        rampBuffer.withUnsafeMutableBufferPointer { rampPtr in
            vDSP_vramp(&startGain, &gainStep, rampPtr.baseAddress!, 1, vDSP_Length(framesToRamp))
            vDSP_vmul(input, 1, rampPtr.baseAddress!, 1, output, 1, vDSP_Length(framesToRamp))
        }
        
        let actualEndGain = startGain + gainStep * Float(framesToRamp)
        currentGain = actualEndGain
        if abs(currentGain - targetGain) < 0.001 {
            currentGain = targetGain
        }
        
        let remainingFrames = frameCount - framesToRamp
        if remainingFrames > 0 {
            let offsetIn = input.advanced(by: framesToRamp)
            let offsetOut = output.advanced(by: framesToRamp)
            if currentGain == 0.0 {
                vDSP_vclr(offsetOut, 1, vDSP_Length(remainingFrames))
            } else if currentGain == 1.0 {
                offsetOut.assign(from: offsetIn, count: remainingFrames)
            } else {
                var gain = currentGain
                vDSP_vsmul(offsetIn, 1, &gain, offsetOut, 1, vDSP_Length(remainingFrames))
            }
        }
    }
}

// MARK: - Unit Tests

struct AudioCoreTests {
    
    @Test func testRingBufferWriteAndRead() {
        let ring = TestRingBuffer(channels: 2, frameCapacity: 1024)
        #expect(ring.availableReadFrames == 0)
        #expect(ring.availableWriteFrames == 1023)
        
        let writeData: [Float] = [0.1, 0.2, 0.3, 0.4]
        writeData.withUnsafeBufferPointer { ptr in
            let written = ring.write(data: ptr.baseAddress!, frameCount: 4, channelIndex: 0)
            #expect(written == 4)
        }
        
        #expect(ring.availableReadFrames == 4)
        
        var readData: [Float] = [0.0, 0.0, 0.0, 0.0]
        let readCount = readData.withUnsafeMutableBufferPointer { ptr in
            return ring.read(destination: ptr.baseAddress!, frameCount: 4, channelIndex: 0)
        }
        
        #expect(readCount == 4)
        #expect(readData == writeData)
        #expect(ring.availableReadFrames == 0)
    }
    
    @Test func testRingBufferUnderrunSilencePadding() {
        let ring = TestRingBuffer(channels: 1, frameCapacity: 64)
        var readData: [Float] = [9.0, 9.0, 9.0]
        
        let readCount = readData.withUnsafeMutableBufferPointer { ptr in
            return ring.read(destination: ptr.baseAddress!, frameCount: 3, channelIndex: 0)
        }
        
        #expect(readCount == 0)
        // Check that destination was filled with silence (0.0)
        #expect(readData == [0.0, 0.0, 0.0])
    }
    
    @Test func testGainRampProcessorSmoothRamping() {
        let processor = TestGainRampProcessor(initialGain: 1.0, rampFrames: 4)
        processor.setTargetGain(0.0)
        
        let inData: [Float] = [1.0, 1.0, 1.0, 1.0, 1.0, 1.0]
        var outData: [Float] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        
        inData.withUnsafeBufferPointer { inPtr in
            outData.withUnsafeMutableBufferPointer { outPtr in
                processor.process(input: inPtr.baseAddress!, output: outPtr.baseAddress!, frameCount: 6)
            }
        }
        
        // Linear ramp down over 4 frames: [1.0, 0.75, 0.5, 0.25, 0.0, 0.0]
        #expect(outData[0] == 1.0)
        #expect(abs(outData[1] - 0.75) < 0.001)
        #expect(abs(outData[2] - 0.50) < 0.001)
        #expect(abs(outData[3] - 0.25) < 0.001)
        #expect(outData[4] == 0.0)
        #expect(outData[5] == 0.0)
    }
    
    @Test func testGainRampProcessorMuteAndPassThrough() {
        let processor = TestGainRampProcessor(initialGain: 0.0, rampFrames: 2)
        
        // Muted test
        let inData: [Float] = [0.8, -0.4, 0.2]
        var outData: [Float] = [1.0, 1.0, 1.0]
        
        inData.withUnsafeBufferPointer { inPtr in
            outData.withUnsafeMutableBufferPointer { outPtr in
                processor.process(input: inPtr.baseAddress!, output: outPtr.baseAddress!, frameCount: 3)
            }
        }
        #expect(outData == [0.0, 0.0, 0.0])
        
        // Immediate reset to 1.0
        processor.resetGain(1.0)
        inData.withUnsafeBufferPointer { inPtr in
            outData.withUnsafeMutableBufferPointer { outPtr in
                processor.process(input: inPtr.baseAddress!, output: outPtr.baseAddress!, frameCount: 3)
            }
        }
        #expect(outData == inData)
    }
}
