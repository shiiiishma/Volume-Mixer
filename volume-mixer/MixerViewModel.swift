import Foundation
import CoreAudio
import SwiftUI
import Observation

@Observable
@MainActor
public final class MixerViewModel {
    public var apps: [AudioAppItem] = []
    public var devices: [AudioOutputDevice] = []
    public var defaultDeviceUID: String = ""
    public var isMuteAll: Bool = false
    
    // Master System Volume
    public var masterVolume: Float = 1.0
    public var isMasterMuted: Bool = false
    
    @ObservationIgnored
    private var activeTaps: [pid_t: ProcessTapSession] = [:]
    
    @ObservationIgnored
    private var meterTimerTask: Task<Void, Never>?
    
    public init() {
        refreshDevices()
        refreshMasterVolume()
        refreshApps()
        startMeteringLoop()
        
        AudioDeviceManager.shared.onDevicesChanged = { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshDevices()
            }
        }
        
        AudioDeviceManager.shared.onMasterVolumeChanged = { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshMasterVolume()
            }
        }
        
        AudioProcessTracker.shared.onProcessesChanged = { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshApps()
            }
        }
    }
    
    deinit {
        meterTimerTask?.cancel()
    }
    
    public func refreshDevices() {
        AudioDeviceManager.shared.refreshDevices()
        self.devices = AudioDeviceManager.shared.devices
        self.defaultDeviceUID = AudioDeviceManager.shared.defaultDeviceUID
    }
    
    public func setDefaultOutputDevice(uid: String) {
        AudioDeviceManager.shared.setDefaultOutputDevice(uid: uid)
        refreshDevices()
    }
    
    public func refreshMasterVolume() {
        self.masterVolume = AudioDeviceManager.shared.getMasterVolume()
        self.isMasterMuted = AudioDeviceManager.shared.isMasterMuted()
    }
    
    public func setMasterVolume(_ volume: Float) {
        self.masterVolume = max(0.0, min(1.0, volume))
        AudioDeviceManager.shared.setMasterVolume(self.masterVolume)
    }
    
    public func toggleMasterMute() {
        self.isMasterMuted.toggle()
        AudioDeviceManager.shared.setMasterMute(self.isMasterMuted)
    }
    
    private func effectiveGain(for app: AudioAppItem) -> Float {
        if isMuteAll || app.isMuted {
            return 0.0
        }
        // Note: The physical output device already applies the system Master Volume
        // at the hardware/DAC stage to all streams. Therefore, the tap session gain
        // is purely the per-app volume multiplier (app.volume).
        return app.volume
    }
    
    public func refreshApps() {
        let currentApps = AudioProcessTracker.shared.fetchActiveAudioApps()
        
        var updatedApps: [AudioAppItem] = []
        for var app in currentApps {
            let prefKey = preferenceKey(for: app)
            
            if let existing = self.apps.first(where: { $0.pid == app.pid }) {
                app.volume = existing.volume
                app.isMuted = existing.isMuted
                app.selectedDeviceUID = existing.selectedDeviceUID
                app.isDRMProtected = existing.isDRMProtected
                app.peakLevel = existing.peakLevel
            } else if let saved = AudioSettingsStore.shared.getPreference(for: prefKey) {
                // Restore persistent preferences
                app.volume = saved.volume
                app.isMuted = saved.isMuted
                app.selectedDeviceUID = saved.deviceUID
            }
            
            // If active tap exists, sync dynamic helper processes
            if let session = activeTaps[app.pid] {
                session.updateProcesses(app.allTargetProcessIDs)
                app.isTapped = true
            } else {
                app.isTapped = false
            }
            
            updatedApps.append(app)
        }
        
        self.apps = updatedApps
        
        // Re-evaluate taps for any discovered apps
        for i in 0..<self.apps.count {
            evaluateTapRequirement(for: i)
        }
    }
    
    public func setVolume(for pid: pid_t, volume: Float) {
        guard let index = apps.firstIndex(where: { $0.pid == pid }) else { return }
        apps[index].volume = volume
        savePreference(for: apps[index])
        if let existing = activeTaps[pid] {
            existing.updateVolume(effectiveGain(for: apps[index]))
        }
        evaluateTapRequirement(for: index)
    }
    
    public func toggleMute(for pid: pid_t) {
        guard let index = apps.firstIndex(where: { $0.pid == pid }) else { return }
        apps[index].isMuted.toggle()
        savePreference(for: apps[index])
        if let existing = activeTaps[pid] {
            existing.updateVolume(effectiveGain(for: apps[index]))
        }
        evaluateTapRequirement(for: index)
    }
    
    public func setOutputDevice(for pid: pid_t, deviceUID: String?) {
        guard let index = apps.firstIndex(where: { $0.pid == pid }) else { return }
        apps[index].selectedDeviceUID = deviceUID
        savePreference(for: apps[index])
        evaluateTapRequirement(for: index)
    }
    
    public func resetApp(for pid: pid_t) {
        guard let index = apps.firstIndex(where: { $0.pid == pid }) else { return }
        apps[index].volume = 1.0
        apps[index].isMuted = false
        apps[index].selectedDeviceUID = nil
        
        let prefKey = preferenceKey(for: apps[index])
        AudioSettingsStore.shared.removePreference(for: prefKey)
        evaluateTapRequirement(for: index)
    }
    
    public func toggleMuteAll() {
        isMuteAll.toggle()
        for i in 0..<apps.count {
            apps[i].isMuted = isMuteAll
            savePreference(for: apps[i])
            if let session = activeTaps[apps[i].pid] {
                session.updateVolume(effectiveGain(for: apps[i]))
            }
            evaluateTapRequirement(for: i)
        }
    }
    
    public func resetAllApps() {
        isMuteAll = false
        AudioSettingsStore.shared.clearAll()
        for i in 0..<apps.count {
            apps[i].volume = 1.0
            apps[i].isMuted = false
            apps[i].selectedDeviceUID = nil
            evaluateTapRequirement(for: i)
        }
    }
    
    private func evaluateTapRequirement(for index: Int) {
        let app = apps[index]
        let targetUID = app.selectedDeviceUID ?? defaultDeviceUID
        
        let targetGain = effectiveGain(for: app)
        // A tap is needed only when the user explicitly attenuated the app (< 0.999), muted it, or redirected output
        let needsTap = (app.volume < 0.999 || app.isMuted || app.selectedDeviceUID != nil)
        
        if needsTap {
            var targetIDs = app.allTargetProcessIDs
            if targetIDs.isEmpty {
                if let directID = AudioProcessTracker.shared.getAudioObjectID(for: app.pid) {
                    targetIDs = [directID]
                    apps[index].audioObjectID = directID
                }
            }
            
            guard !targetIDs.isEmpty else {
                return
            }
            
            if let existingSession = activeTaps[app.pid] {
                existingSession.updateProcesses(targetIDs)
                existingSession.updateVolume(targetGain)
                existingSession.updateOutputDevice(uid: targetUID)
            } else {
                do {
                    let session = try ProcessTapSession(
                        processObjectIDs: targetIDs,
                        pid: app.pid,
                        bundleID: app.bundleID,
                        initialVolume: targetGain,
                        isMuted: app.isMuted,
                        outputDeviceUID: targetUID
                    )
                    
                    session.onDRMDetected = { [weak self] isDRM in
                        Task { @MainActor [weak self] in
                            guard let self = self,
                                  let idx = self.apps.firstIndex(where: { $0.pid == app.pid }) else { return }
                            self.apps[idx].isDRMProtected = isDRM
                        }
                    }
                    
                    activeTaps[app.pid] = session
                    apps[index].isTapped = true
                } catch {
                    NSLog("[MixerViewModel] Failed to create tap for \(app.name): \(error)")
                }
            }
        } else {
            if activeTaps[app.pid] != nil {
                activeTaps.removeValue(forKey: app.pid)
                apps[index].isTapped = false
                apps[index].peakLevel = 0.0
            }
        }
    }
    
    private func startMeteringLoop() {
        meterTimerTask?.cancel()
        meterTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 33_000_000) // ~30 FPS
                guard let self = self else { return }
                
                for i in 0..<self.apps.count {
                    let pid = self.apps[i].pid
                    if let session = self.activeTaps[pid] {
                        let rawPeak = session.getAndResetPeak()
                        let decayed = self.apps[i].peakLevel * 0.72
                        let effective = (self.isMasterMuted || self.isMuteAll || self.apps[i].isMuted) ? 0.0 : max(rawPeak, decayed)
                        self.apps[i].peakLevel = effective
                    } else {
                        if self.apps[i].peakLevel > 0 {
                            self.apps[i].peakLevel = 0.0
                        }
                    }
                }
            }
        }
    }
    
    private func savePreference(for app: AudioAppItem) {
        let key = preferenceKey(for: app)
        let pref = AppAudioPreference(
            volume: app.volume,
            isMuted: app.isMuted,
            deviceUID: app.selectedDeviceUID
        )
        AudioSettingsStore.shared.savePreference(pref, for: key)
    }
    
    private func preferenceKey(for app: AudioAppItem) -> String {
        return app.bundleID.isEmpty ? "name:\(app.name)" : "bundle:\(app.bundleID)"
    }
}
