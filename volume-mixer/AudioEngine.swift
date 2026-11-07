import Foundation
import CoreAudio
import Accelerate
import AppKit
import os.lock

// MARK: - Process Tap Session
public final class ProcessTapSession: @unchecked Sendable {
    public private(set) var processObjectIDs: [AudioObjectID]
    public let pid: pid_t
    public let bundleID: String
    
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    
    private var lock = os_unfair_lock_s()
    private var currentVolume: Float = 1.0
    private var isMutedState: Bool = false
    private var outputDeviceUID: String
    
    // Smooth gain ramping per audio channel
    private var channelProcessors: [GainRampProcessor] = []
    
    // DRM detection state
    private var silentFrameCount: Int = 0
    public var onDRMDetected: (@Sendable (Bool) -> Void)?
    private var reportedDRM: Bool = false
    
    // Real-time peak level monitoring
    private var latestPeak: Float = 0.0
    
    public func getAndResetPeak() -> Float {
        let p = latestPeak
        latestPeak = 0.0
        return p
    }

    public init(
        processObjectIDs: [AudioObjectID],
        pid: pid_t,
        bundleID: String,
        initialVolume: Float = 1.0,
        isMuted: Bool = false,
        outputDeviceUID: String
    ) throws {
        self.processObjectIDs = processObjectIDs
        self.pid = pid
        self.bundleID = bundleID
        self.currentVolume = initialVolume
        self.isMutedState = isMuted
        self.outputDeviceUID = outputDeviceUID
        
        // Initialize processors for stereo default
        let effectiveGain = isMuted ? 0.0 : initialVolume
        self.channelProcessors = [
            GainRampProcessor(initialGain: effectiveGain, rampFrames: 128),
            GainRampProcessor(initialGain: effectiveGain, rampFrames: 128)
        ]
        
        try startTap()
    }
    
    deinit {
        stopTap()
    }
    
    public func updateVolume(_ volume: Float) {
        os_unfair_lock_lock(&lock)
        currentVolume = volume
        let target = isMutedState ? 0.0 : volume
        for proc in channelProcessors {
            proc.setTargetGain(target)
        }
        os_unfair_lock_unlock(&lock)
    }
    
    public func updateMute(_ isMuted: Bool) {
        os_unfair_lock_lock(&lock)
        isMutedState = isMuted
        let target = isMuted ? 0.0 : currentVolume
        for proc in channelProcessors {
            proc.setTargetGain(target)
        }
        os_unfair_lock_unlock(&lock)
    }
    
    public func updateProcesses(_ newProcesses: [AudioObjectID]) {
        os_unfair_lock_lock(&lock)
        let changed = Set(processObjectIDs) != Set(newProcesses)
        processObjectIDs = newProcesses
        os_unfair_lock_unlock(&lock)
        
        if changed {
            stopTap()
            do {
                try startTap()
            } catch {
                NSLog("[ProcessTapSession] Failed to restart tap after process update: \(error)")
            }
        }
    }
    
    public func updateOutputDevice(uid: String) {
        os_unfair_lock_lock(&lock)
        let changed = (outputDeviceUID != uid)
        outputDeviceUID = uid
        os_unfair_lock_unlock(&lock)
        
        if changed {
            stopTap()
            do {
                try startTap()
            } catch {
                NSLog("[ProcessTapSession] Failed to switch output device: \(error)")
            }
        }
    }
    
    private func startTap() throws {
        // 1. Create CATapDescription
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        
        if #available(macOS 14.2, *) {
            tapDescription.processes = self.processObjectIDs
            tapDescription.muteBehavior = .mutedWhenTapped
        }
        
        var newTapID: AudioObjectID = kAudioObjectUnknown
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard tapStatus == noErr, newTapID != kAudioObjectUnknown else {
            throw NSError(domain: "AudioEngine", code: Int(tapStatus), userInfo: [NSLocalizedDescriptionKey: "Failed to create Process Tap (\(tapStatus))"])
        }
        self.tapID = newTapID
        
        // 2. Create Aggregate Device routing to selected output device
        let targetDeviceUID = self.outputDeviceUID
        let aggregateUID = "com.antigravity.tap.\(pid).\(UUID().uuidString)"
        
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AntigravityTap-\(pid)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: targetDeviceUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: targetDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: aggregateUID + ".tap",
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]
        
        var newAggregateID: AudioDeviceID = kAudioObjectUnknown
        let aggStatus = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &newAggregateID)
        guard aggStatus == noErr, newAggregateID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(newTapID)
            self.tapID = kAudioObjectUnknown
            throw NSError(domain: "AudioEngine", code: Int(aggStatus), userInfo: [NSLocalizedDescriptionKey: "Failed to create Aggregate Device (\(aggStatus))"])
        }
        self.aggregateDeviceID = newAggregateID
        
        // 3. Register IOProc on Aggregate Device
        let ioBlock: AudioDeviceIOProc = { _, _, inInputData, _, outOutputData, _, inClientData in
            guard let clientData = inClientData else { return noErr }
            let session = Unmanaged<ProcessTapSession>.fromOpaque(clientData).takeUnretainedValue()
            
            session.processAudio(input: inInputData, output: outOutputData)
            return noErr
        }
        
        var newIOProcID: AudioDeviceIOProcID?
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let ioStatus = AudioDeviceCreateIOProcID(newAggregateID, ioBlock, selfPtr, &newIOProcID)
        guard ioStatus == noErr, let procID = newIOProcID else {
            AudioHardwareDestroyAggregateDevice(newAggregateID)
            AudioHardwareDestroyProcessTap(newTapID)
            self.aggregateDeviceID = kAudioObjectUnknown
            self.tapID = kAudioObjectUnknown
            throw NSError(domain: "AudioEngine", code: Int(ioStatus), userInfo: [NSLocalizedDescriptionKey: "Failed to create IOProcID (\(ioStatus))"])
        }
        self.ioProcID = procID
        
        // 4. Start IO Device
        let startStatus = AudioDeviceStart(newAggregateID, procID)
        if startStatus != noErr {
            NSLog("[ProcessTapSession] AudioDeviceStart returned \(startStatus)")
        }
    }
    
    private func stopTap() {
        if let procID = ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            ioProcID = nil
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }
    
    private func processAudio(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outBuffers = UnsafeMutableAudioBufferListPointer(output)
        
        let bufferCount = min(inBuffers.count, outBuffers.count)
        guard bufferCount > 0 else { return }
        
        // Ensure we have a GainRampProcessor for each channel
        if channelProcessors.count < bufferCount {
            os_unfair_lock_lock(&lock)
            let effectiveGain = isMutedState ? 0.0 : currentVolume
            while channelProcessors.count < bufferCount {
                channelProcessors.append(GainRampProcessor(initialGain: effectiveGain, rampFrames: 128))
            }
            os_unfair_lock_unlock(&lock)
        }
        
        var maxPeak: Float = 0.0
        
        for i in 0..<bufferCount {
            let inBuf = inBuffers[i]
            let outBuf = outBuffers[i]
            
            guard let inData = inBuf.mData?.assumingMemoryBound(to: Float.self),
                  let outData = outBuf.mData?.assumingMemoryBound(to: Float.self) else {
                continue
            }
            
            let frameCount = Int(inBuf.mDataByteSize) / MemoryLayout<Float>.size
            if frameCount > 0 {
                // Peak detection for DRM silence watchdog & VU metering
                var channelPeak: Float = 0.0
                vDSP_maxmgv(inData, 1, &channelPeak, vDSP_Length(frameCount))
                if channelPeak > maxPeak {
                    maxPeak = channelPeak
                }
                
                // Process audio with smooth gain ramping
                channelProcessors[i].process(input: inData, output: outData, frameCount: frameCount)
            }
        }
        
        if maxPeak > latestPeak {
            latestPeak = maxPeak
        }
        
        // DRM Watchdog check
        if maxPeak < 0.00001 {
            silentFrameCount += 1
            if silentFrameCount > 60 && !reportedDRM { // ~1.5 - 2 seconds of total silence while active
                reportedDRM = true
                onDRMDetected?(true)
            }
        } else {
            silentFrameCount = 0
            if reportedDRM {
                reportedDRM = false
                onDRMDetected?(false)
            }
        }
    }
}

// MARK: - Audio Device Manager
public final class AudioDeviceManager: @unchecked Sendable {
    public static let shared = AudioDeviceManager()
    
    public private(set) var devices: [AudioOutputDevice] = []
    public private(set) var defaultDeviceUID: String = ""
    public var onDevicesChanged: (@Sendable () -> Void)?
    
    private init() {
        refreshDevices()
        setupListeners()
    }
    
    public func refreshDevices() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr, dataSize > 0 else { return }
        
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.stride
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else { return }
        
        let defUID = getDefaultOutputDeviceUID()
        self.defaultDeviceUID = defUID
        
        var outputList: [AudioOutputDevice] = []
        for devID in deviceIDs {
            if hasOutputStreams(deviceID: devID),
               let uid = getDeviceUID(deviceID: devID),
               let name = getDeviceName(deviceID: devID) {
                // Ignore virtual aggregate taps created by this app
                if uid.contains("com.antigravity.tap.") {
                    continue
                }
                let isDef = (uid == defUID)
                outputList.append(AudioOutputDevice(id: devID, uid: uid, name: name, isDefault: isDef))
            }
        }
        
        self.devices = outputList
    }
    
    public func getDefaultOutputDeviceUID() -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var defaultID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &defaultID
        )
        guard status == noErr, defaultID != kAudioObjectUnknown else { return "" }
        return getDeviceUID(deviceID: defaultID) ?? ""
    }
    
    private func hasOutputStreams(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return false }
        
        let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(dataSize))
        defer { bufferListPtr.deallocate() }
        
        let getStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferListPtr)
        guard getStatus == noErr else { return false }
        
        let bufferList = bufferListPtr.pointee
        return bufferList.mNumberBuffers > 0
    }
    
    private func getDeviceUID(deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfUID)
        guard status == noErr, let uid = cfUID?.takeRetainedValue() as String? else { return nil }
        return uid
    }
    
    private func getDeviceName(deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfName)
        guard status == noErr, let name = cfName?.takeRetainedValue() as String? else { return nil }
        return name
    }
    
    private func setupListeners() {
        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddr,
            DispatchQueue.main
        ) { [weak self] _, _ in
            self?.refreshDevices()
            self?.onDevicesChanged?()
        }
        
        var devAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devAddr,
            DispatchQueue.main
        ) { [weak self] _, _ in
            self?.refreshDevices()
            self?.onDevicesChanged?()
        }
    }
}

// MARK: - Audio Process Tracker
public final class AudioProcessTracker: @unchecked Sendable {
    public static let shared = AudioProcessTracker()
    
    public var onProcessesChanged: (@Sendable () -> Void)?
    
    private init() {
        setupListener()
    }
    
    public func fetchActiveAudioApps() -> [AudioAppItem] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr, dataSize > 0 else { return [] }
        
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.stride
        var processIDs = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &processIDs
        )
        guard status == noErr else { return [] }
        
        let ownPID = ProcessInfo.processInfo.processIdentifier
        
        // First pass: Collect all processes
        struct RawProcess {
            let objectID: AudioObjectID
            let pid: pid_t
            let bundleID: String
            let name: String
            let isRunning: Bool
        }
        
        var rawList: [RawProcess] = []
        for objID in processIDs {
            let pid = getPID(for: objID)
            guard pid > 0, pid != ownPID else { continue }
            
            let isRunning = isProcessRunningOutput(objectID: objID)
            let bundleID = getBundleID(for: objID) ?? ""
            let name = getProcessName(for: objID, pid: pid)
            
            // Filter noise daemons that don't output user audio
            let lower = name.lowercased()
            if lower == "launchd" || lower == "kernel_task" || lower == "distnoted" || lower == "audiomixer" {
                continue
            }
            
            rawList.append(RawProcess(
                objectID: objID,
                pid: pid,
                bundleID: bundleID,
                name: name,
                isRunning: isRunning
            ))
        }
        
        // Second pass: Group browser helper processes under their parent application
        var grouped: [AudioAppItem] = []
        var consumedObjectIDs = Set<AudioObjectID>()
        
        // Group by bundleID (or bundle prefix)
        for raw in rawList {
            guard !consumedObjectIDs.contains(raw.objectID) else { continue }
            
            // Check if this is a helper process (e.g., Google Chrome Helper, com.google.Chrome.helper)
            let isHelper = raw.name.contains("Helper") || raw.bundleID.contains(".helper") || raw.bundleID.contains(".WebKit.GPU")
            
            if !isHelper {
                // Find any helper children
                var childIDs: [AudioObjectID] = []
                var anyRunning = raw.isRunning
                
                for other in rawList where other.objectID != raw.objectID {
                    let isChildOfThis = (!raw.bundleID.isEmpty && other.bundleID.hasPrefix(raw.bundleID)) ||
                                        (other.name.hasPrefix(raw.name) && other.name.contains("Helper"))
                    if isChildOfThis {
                        childIDs.append(other.objectID)
                        consumedObjectIDs.insert(other.objectID)
                        if other.isRunning { anyRunning = true }
                    }
                }
                
                consumedObjectIDs.insert(raw.objectID)
                grouped.append(AudioAppItem(
                    audioObjectID: raw.objectID,
                    pid: raw.pid,
                    bundleID: raw.bundleID,
                    name: raw.name,
                    childObjectIDs: childIDs,
                    isRunningOutput: anyRunning
                ))
            }
        }
        
        // Include any remaining orphan processes
        for raw in rawList {
            if !consumedObjectIDs.contains(raw.objectID) {
                grouped.append(AudioAppItem(
                    audioObjectID: raw.objectID,
                    pid: raw.pid,
                    bundleID: raw.bundleID,
                    name: raw.name,
                    childObjectIDs: [],
                    isRunningOutput: raw.isRunning
                ))
            }
        }
        
        // Sort: Active apps first, then alphabetically
        return grouped.sorted {
            if $0.isRunningOutput != $1.isRunningOutput {
                return $0.isRunningOutput && !$1.isRunningOutput
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
    
    private func getPID(for objectID: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &pid)
        return status == noErr ? pid : 0
    }
    
    private func getBundleID(for objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfBundle: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &cfBundle)
        guard status == noErr, let bundle = cfBundle?.takeRetainedValue() as String? else { return nil }
        return bundle
    }
    
    private func isProcessRunningOutput(objectID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunning,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &isRunning)
        return status == noErr && isRunning != 0
    }
    
    private func getProcessName(for objectID: AudioObjectID, pid: pid_t) -> String {
        // Try NSRunningApplication first for localized name
        if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName {
            return name
        }
        
        // Fallback to Core Audio Process Object Name
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &cfName)
        if status == noErr, let name = cfName?.takeRetainedValue() as String?, !name.isEmpty {
            return name
        }
        
        return "Process \(pid)"
    }
    
    private func setupListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main
        ) { [weak self] _, _ in
            self?.onProcessesChanged?()
        }
    }
}
