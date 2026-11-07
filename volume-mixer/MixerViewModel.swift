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
    public var searchQuery: String = ""
    public var isMuteAll: Bool = false
    
    @ObservationIgnored
    private var activeTaps: [AudioObjectID: ProcessTapSession] = [:]
    
    @ObservationIgnored
    private var meterTimerTask: Task<Void, Never>?
    
    public var filteredApps: [AudioAppItem] {
        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return apps
        }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(searchQuery) ||
            $0.bundleID.localizedCaseInsensitiveContains(searchQuery)
        }
    }
    
    public init() {
        refreshDevices()
        refreshApps()
        startMeteringLoop()
        
        AudioDeviceManager.shared.onDevicesChanged = { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshDevices()
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
    
    public func refreshApps() {
        let currentApps = AudioProcessTracker.shared.fetchActiveAudioApps()
        
        var updatedApps: [AudioAppItem] = []
        for var app in currentApps {
            let prefKey = preferenceKey(for: app)
            
            if let existing = self.apps.first(where: { $0.audioObjectID == app.audioObjectID }) {
                app.volume = existing.volume
                app.isMuted = existing.isMuted
                app.selectedDeviceUID = existing.selectedDeviceUID
                app.isDRMProtected = existing.isDRMProtected
                app.peakLevel = existing.peakLevel
            } else if let saved = AudioSettingsStore.shared.getPreference(for: prefKey) {
                // Restore persistent preferences!
                app.volume = saved.volume
                app.isMuted = saved.isMuted
                app.selectedDeviceUID = saved.deviceUID
            }
            
            // If active tap exists, sync dynamic helper processes
            if let session = activeTaps[app.audioObjectID] {
                session.updateProcesses(app.allTargetProcessIDs)
                app.isTapped = true
            } else {
                app.isTapped = false
            }
            
            updatedApps.append(app)
        }
        
        self.apps = updatedApps
        
        // Re-evaluate taps for any newly discovered apps with saved preferences
        for i in 0..<self.apps.count {
            evaluateTapRequirement(for: i)
        }
    }
    
    public func setVolume(for appID: AudioObjectID, volume: Float) {
        guard let index = apps.firstIndex(where: { $0.audioObjectID == appID }) else { return }
        apps[index].volume = volume
        savePreference(for: apps[index])
        evaluateTapRequirement(for: index)
    }
    
    public func toggleMute(for appID: AudioObjectID) {
        guard let index = apps.firstIndex(where: { $0.audioObjectID == appID }) else { return }
        apps[index].isMuted.toggle()
        savePreference(for: apps[index])
        evaluateTapRequirement(for: index)
    }
    
    public func setOutputDevice(for appID: AudioObjectID, deviceUID: String?) {
        guard let index = apps.firstIndex(where: { $0.audioObjectID == appID }) else { return }
        apps[index].selectedDeviceUID = deviceUID
        savePreference(for: apps[index])
        evaluateTapRequirement(for: index)
    }
    
    public func resetApp(for appID: AudioObjectID) {
        guard let index = apps.firstIndex(where: { $0.audioObjectID == appID }) else { return }
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
    
    private func preferenceKey(for app: AudioAppItem) -> String {
        return app.bundleID.isEmpty ? app.name : app.bundleID
    }
    
    private func savePreference(for app: AudioAppItem) {
        let prefKey = preferenceKey(for: app)
        if app.volume >= 0.999 && !app.isMuted && app.selectedDeviceUID == nil {
            AudioSettingsStore.shared.removePreference(for: prefKey)
        } else {
            let pref = AppAudioPreference(volume: app.volume, isMuted: app.isMuted, deviceUID: app.selectedDeviceUID)
            AudioSettingsStore.shared.savePreference(pref, for: prefKey)
        }
    }
    
    private func evaluateTapRequirement(for index: Int) {
        let app = apps[index]
        let targetUID = app.selectedDeviceUID ?? defaultDeviceUID
        
        let needsTap = (app.volume < 0.999 || app.isMuted || app.selectedDeviceUID != nil)
        
        if needsTap {
            if let existingSession = activeTaps[app.audioObjectID] {
                existingSession.updateVolume(app.volume)
                existingSession.updateMute(app.isMuted)
                existingSession.updateOutputDevice(uid: targetUID)
            } else {
                do {
                    let session = try ProcessTapSession(
                        processObjectIDs: app.allTargetProcessIDs,
                        pid: app.pid,
                        bundleID: app.bundleID,
                        initialVolume: app.volume,
                        isMuted: app.isMuted,
                        outputDeviceUID: targetUID
                    )
                    
                    session.onDRMDetected = { [weak self] isDRM in
                        Task { @MainActor [weak self] in
                            guard let self = self,
                                  let idx = self.apps.firstIndex(where: { $0.audioObjectID == app.audioObjectID }) else { return }
                            self.apps[idx].isDRMProtected = isDRM
                        }
                    }
                    
                    activeTaps[app.audioObjectID] = session
                    apps[index].isTapped = true
                } catch {
                    NSLog("[MixerViewModel] Failed to create tap for \(app.name): \(error)")
                }
            }
        } else {
            // On-demand release: destroy tap and return app to direct system audio!
            if activeTaps[app.audioObjectID] != nil {
                activeTaps.removeValue(forKey: app.audioObjectID)
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
                    let appID = self.apps[i].audioObjectID
                    if let session = self.activeTaps[appID] {
                        let rawPeak = session.getAndResetPeak()
                        let decayed = self.apps[i].peakLevel * 0.72
                        let effective = self.apps[i].isMuted ? 0.0 : max(rawPeak, decayed)
                        self.apps[i].peakLevel = min(1.0, effective)
                    } else {
                        if self.apps[i].peakLevel > 0.01 {
                            self.apps[i].peakLevel *= 0.72
                        } else {
                            self.apps[i].peakLevel = 0.0
                        }
                    }
                }
            }
        }
    }
}
