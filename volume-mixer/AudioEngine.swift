import Foundation
import CoreAudio
import AudioToolbox
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
        let currentTapID = tapID
        os_unfair_lock_unlock(&lock)
        
        if changed && !newProcesses.isEmpty {
            if currentTapID != kAudioObjectUnknown {
                if #available(macOS 14.2, *) {
                    let tap = AudioHardwareTap(id: currentTapID)
                    let newDesc = CATapDescription(stereoMixdownOfProcesses: newProcesses)
                    newDesc.muteBehavior = .mutedWhenTapped
                    do {
                        try tap.setDescription(newDesc)
                        return
                    } catch {
                        NSLog("[ProcessTapSession] setDescription failed, recreating tap: \(error)")
                    }
                }
            }
            
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
        guard !processObjectIDs.isEmpty else {
            throw NSError(domain: "AudioEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "No processes to tap"])
        }
        
        // 1. Create CATapDescription with stereo mixdown of target processes
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: self.processObjectIDs)
        tapDescription.muteBehavior = .mutedWhenTapped
        
        var newTapID: AudioObjectID = kAudioObjectUnknown
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard tapStatus == noErr, newTapID != kAudioObjectUnknown else {
            throw NSError(domain: "AudioEngine", code: Int(tapStatus), userInfo: [NSLocalizedDescriptionKey: "Failed to create Process Tap (\(tapStatus))"])
        }
        self.tapID = newTapID
        
        // 2. Create Aggregate Device routing to selected output device
        let targetDeviceUID = self.outputDeviceUID
        let aggregateUID = "com.antigravity.tap.\(pid).\(UUID().uuidString)"
        let tapUID = tapDescription.uuid.uuidString
        
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AntigravityTap-\(pid)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: targetDeviceUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: targetDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: 1
                ]
            ],
            kAudioAggregateDeviceIsPrivateKey: 1
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
        
        guard let inBuf = inBuffers.first,
              let outBuf = outBuffers.first,
              let inData = inBuf.mData?.assumingMemoryBound(to: Float.self),
              let outData = outBuf.mData?.assumingMemoryBound(to: Float.self) else {
            return
        }
        
        let inBytes = Int(inBuf.mDataByteSize)
        let outBytes = Int(outBuf.mDataByteSize)
        let processBytes = min(inBytes, outBytes)
        let sampleCount = processBytes / MemoryLayout<Float>.size
        
        if sampleCount > 0 {
            // Peak detection for DRM silence watchdog & VU metering
            var channelPeak: Float = 0.0
            vDSP_maxmgv(inData, 1, &channelPeak, vDSP_Length(sampleCount))
            if channelPeak > latestPeak {
                latestPeak = channelPeak
            }
            
            // DRM Watchdog check
            if channelPeak < 0.00001 {
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
            
            // Process audio with smooth gain ramping
            if channelProcessors.isEmpty {
                os_unfair_lock_lock(&lock)
                let effectiveGain = isMutedState ? 0.0 : currentVolume
                channelProcessors.append(GainRampProcessor(initialGain: effectiveGain, rampFrames: 128))
                os_unfair_lock_unlock(&lock)
            }
            channelProcessors[0].process(input: inData, output: outData, frameCount: sampleCount)
        }
        
        // If output buffer is larger than input, zero out the rest
        if outBytes > inBytes {
            let remainingBytes = outBytes - inBytes
            let remainingFloatPtr = outData.advanced(by: sampleCount)
            let remainingFloats = remainingBytes / MemoryLayout<Float>.size
            vDSP_vclr(remainingFloatPtr, 1, vDSP_Length(remainingFloats))
        }
    }
}

// MARK: - Audio Device Manager
public final class AudioDeviceManager: @unchecked Sendable {
    public static let shared = AudioDeviceManager()
    
    public private(set) var devices: [AudioOutputDevice] = []
    public private(set) var defaultDeviceUID: String = ""
    public var onDevicesChanged: (@Sendable () -> Void)?
    public var onMasterVolumeChanged: (@Sendable () -> Void)?
    
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
    
    public func getDefaultOutputDeviceID() -> AudioDeviceID {
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
        return status == noErr ? defaultID : kAudioObjectUnknown
    }
    
    public func getDefaultOutputDeviceUID() -> String {
        let defaultID = getDefaultOutputDeviceID()
        guard defaultID != kAudioObjectUnknown else { return "" }
        return getDeviceUID(deviceID: defaultID) ?? ""
    }
    
    public func setDefaultOutputDevice(uid: String) {
        guard let dev = devices.first(where: { $0.uid == uid }) else { return }
        var devID = dev.id
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            size,
            &devID
        )
    }
    
    public func getMasterVolume() -> Float {
        let defaultID = getDefaultOutputDeviceID()
        guard defaultID != kAudioObjectUnknown else { return 1.0 }
        
        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var volume: Float32 = 1.0
        var volSize = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(defaultID, &volAddr, 0, nil, &volSize, &volume)
        if status == noErr {
            return Float(volume)
        }
        
        volAddr.mSelector = kAudioDevicePropertyVolumeScalar
        volAddr.mElement = 0
        let status2 = AudioObjectGetPropertyData(defaultID, &volAddr, 0, nil, &volSize, &volume)
        return status2 == noErr ? Float(volume) : 1.0
    }
    
    public func setMasterVolume(_ volume: Float) {
        let defaultID = getDefaultOutputDeviceID()
        guard defaultID != kAudioObjectUnknown else { return }
        
        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var newVol: Float32 = Float32(max(0.0, min(1.0, volume)))
        let volSize = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectSetPropertyData(defaultID, &volAddr, 0, nil, volSize, &newVol)
        if status != noErr {
            volAddr.mSelector = kAudioDevicePropertyVolumeScalar
            volAddr.mElement = 0
            _ = AudioObjectSetPropertyData(defaultID, &volAddr, 0, nil, volSize, &newVol)
        }
    }
    
    public func isMasterMuted() -> Bool {
        let defaultID = getDefaultOutputDeviceID()
        guard defaultID != kAudioObjectUnknown else { return false }
        
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var isMuted: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(defaultID, &muteAddr, 0, nil, &muteSize, &isMuted)
        return status == noErr && isMuted != 0
    }
    
    public func setMasterMute(_ muted: Bool) {
        let defaultID = getDefaultOutputDeviceID()
        guard defaultID != kAudioObjectUnknown else { return }
        
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var newMute: UInt32 = muted ? 1 : 0
        let muteSize = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectSetPropertyData(defaultID, &muteAddr, 0, nil, muteSize, &newMute)
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
            self?.onMasterVolumeChanged?()
            self?.attachDefaultDeviceVolumeListener()
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
        
        attachDefaultDeviceVolumeListener()
    }
    
    private func attachDefaultDeviceVolumeListener() {
        let devID = getDefaultOutputDeviceID()
        guard devID != kAudioObjectUnknown else { return }
        
        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            devID,
            &volAddr,
            DispatchQueue.main
        ) { [weak self] _, _ in
            self?.onMasterVolumeChanged?()
        }
        
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            devID,
            &muteAddr,
            DispatchQueue.main
        ) { [weak self] _, _ in
            self?.onMasterVolumeChanged?()
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
        
        var caProcessIDs: [AudioObjectID] = []
        if status == noErr && dataSize > 0 {
            let count = Int(dataSize) / MemoryLayout<AudioObjectID>.stride
            caProcessIDs = [AudioObjectID](repeating: 0, count: count)
            status = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                &caProcessIDs
            )
        }
        
        let ownPID = ProcessInfo.processInfo.processIdentifier
        
        // Collect all Core Audio process objects
        struct CAProcessInfo {
            let objectID: AudioObjectID
            let pid: pid_t
            let bundleID: String
            let name: String
            let isRunning: Bool
        }
        
        var caList: [CAProcessInfo] = []
        for objID in caProcessIDs {
            let pid = getPID(for: objID)
            guard pid > 0, pid != ownPID else { continue }
            
            let isRunning = isProcessRunningOutput(objectID: objID)
            let bundleID = getBundleID(for: objID) ?? ""
            let name = getProcessName(for: objID, pid: pid)
            
            let lowerName = name.lowercased()
            let lowerBundle = bundleID.lowercased()
            if lowerName.contains("volume-mixer") || lowerName.contains("volume mixer") ||
               lowerBundle.contains("volume-mixer") || lowerBundle.contains("volumemixer") {
                continue
            }
            
            caList.append(CAProcessInfo(
                objectID: objID,
                pid: pid,
                bundleID: bundleID,
                name: name,
                isRunning: isRunning
            ))
        }
        
        let ignoredDaemons: Set<String> = [
            "launchd", "kernel_task", "distnoted", "audiomixer", "callservicesd",
            "avconferenced", "universalaccessd", "powerchime", "loginwindow",
            "windowmanager", "coreservicesuiagent", "dock", "systemuiserver",
            "control center", "control centre", "talagentd", "wallpaper",
            "backgroundtaskmanagementagent", "menubaragent", "corelocationagent",
            "siri", "accessibilityvisualsagent", "notification center",
            "notification centre", "appssoagent", "wifiagent", "accessibilityuiserver",
            "airplayuiagent", "textinputmenuagent", "textinputswitcher",
            "universalcontrol", "aquaappearancehelper", "coreautha", "previewshellmac"
        ]
        
        // 1. Get all currently running regular user GUI applications and non-daemon accessory apps
        var openApps: [NSRunningApplication] = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.processIdentifier != ownPID else { continue }
            let name = (app.localizedName ?? "").lowercased()
            let bundle = (app.bundleIdentifier ?? "").lowercased()
            if name.contains("volume-mixer") || name.contains("volume mixer") ||
               bundle.contains("volume-mixer") || bundle.contains("volumemixer") ||
               ignoredDaemons.contains(name) || ignoredDaemons.contains(bundle) {
                continue
            }
            if app.activationPolicy == .regular {
                openApps.append(app)
            } else if app.activationPolicy == .accessory {
                if !bundle.hasPrefix("com.apple.") && !name.contains("agent") && !name.contains("service") && !name.contains("helper") {
                    openApps.append(app)
                }
            }
        }
        
        var resultList: [AudioAppItem] = []
        var consumedPIDs = Set<pid_t>()
        
        for app in openApps {
            let pid = app.processIdentifier
            let bundleID = app.bundleIdentifier ?? ""
            let name = app.localizedName ?? "Application"
            consumedPIDs.insert(pid)
            
            // Find primary AudioObjectID
            let primaryCA = caList.first(where: { $0.pid == pid })
            let primaryObjID = primaryCA?.objectID ?? kAudioObjectUnknown
            
            // Find helper processes belonging to this app (e.g., Google Chrome Helper, WebKit.GPU)
            let helpers = caList.filter { ca in
                guard ca.pid != pid else { return false }
                if !bundleID.isEmpty && (ca.bundleID.hasPrefix(bundleID) || ca.bundleID.contains(bundleID)) {
                    return true
                }
                if ca.name.hasPrefix(name) && ca.name.contains("Helper") {
                    return true
                }
                return false
            }
            
            for h in helpers {
                consumedPIDs.insert(h.pid)
            }
            
            let isPlaying = (primaryCA?.isRunning ?? false) || helpers.contains(where: { $0.isRunning })
            
            resultList.append(AudioAppItem(
                audioObjectID: primaryObjID,
                pid: pid,
                bundleID: bundleID,
                name: name,
                childObjectIDs: helpers.map { $0.objectID },
                isRunningOutput: isPlaying
            ))
        }
        
        // 2. Also include any accessory / menu bar app that is actively outputting sound
        for ca in caList where ca.isRunning && !consumedPIDs.contains(ca.pid) {
            let lower = ca.name.lowercased()
            let lowerBundle = ca.bundleID.lowercased()
            if lower.contains("volume-mixer") || lower.contains("volume mixer") ||
               lowerBundle.contains("volume-mixer") || lowerBundle.contains("volumemixer") ||
               ignoredDaemons.contains(lower) || ignoredDaemons.contains(lowerBundle) {
                continue
            }
            
            consumedPIDs.insert(ca.pid)
            resultList.append(AudioAppItem(
                audioObjectID: ca.objectID,
                pid: ca.pid,
                bundleID: ca.bundleID,
                name: ca.name,
                childObjectIDs: [],
                isRunningOutput: true
            ))
        }
        
        // Sort: actively playing first, then alphabetically
        return resultList.sorted {
            if $0.isRunningOutput != $1.isRunningOutput {
                return $0.isRunningOutput && !$1.isRunningOutput
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
    
    public func getAudioObjectID(for pid: pid_t) -> AudioObjectID? {
        var inPID = pid
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var objID: AudioObjectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &inPID,
            &size,
            &objID
        )
        return (status == noErr && objID != kAudioObjectUnknown && objID != 0) ? objID : nil
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
        
        // Listen to app launch/terminate notifications from NSWorkspace
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.onProcessesChanged?()
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.onProcessesChanged?()
        }
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.onProcessesChanged?()
        }
    }
}
