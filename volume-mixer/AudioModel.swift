import Foundation
import CoreAudio

public struct AudioOutputDevice: Identifiable, Hashable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let isDefault: Bool
    
    public init(id: AudioDeviceID, uid: String, name: String, isDefault: Bool) {
        self.id = id
        self.uid = uid
        self.name = name
        self.isDefault = isDefault
    }
}

public struct AudioAppItem: Identifiable, Sendable {
    public var id: AudioObjectID { audioObjectID }
    
    public let audioObjectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String
    public let name: String
    public var childObjectIDs: [AudioObjectID]
    public var isRunningOutput: Bool
    
    public var volume: Float
    public var isMuted: Bool
    public var selectedDeviceUID: String?
    public var isDRMProtected: Bool
    public var isTapped: Bool
    public var peakLevel: Float
    
    public var allTargetProcessIDs: [AudioObjectID] {
        return [audioObjectID] + childObjectIDs
    }
    
    public init(
        audioObjectID: AudioObjectID,
        pid: pid_t,
        bundleID: String,
        name: String,
        childObjectIDs: [AudioObjectID] = [],
        isRunningOutput: Bool = false,
        volume: Float = 1.0,
        isMuted: Bool = false,
        selectedDeviceUID: String? = nil,
        isDRMProtected: Bool = false,
        isTapped: Bool = false,
        peakLevel: Float = 0.0
    ) {
        self.audioObjectID = audioObjectID
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.childObjectIDs = childObjectIDs
        self.isRunningOutput = isRunningOutput
        self.volume = volume
        self.isMuted = isMuted
        self.selectedDeviceUID = selectedDeviceUID
        self.isDRMProtected = isDRMProtected
        self.isTapped = isTapped
        self.peakLevel = peakLevel
    }
}

// MARK: - Persistence Model

public struct AppAudioPreference: Codable, Sendable {
    public var volume: Float
    public var isMuted: Bool
    public var deviceUID: String?
    
    public init(volume: Float, isMuted: Bool, deviceUID: String?) {
        self.volume = volume
        self.isMuted = isMuted
        self.deviceUID = deviceUID
    }
}

public final class AudioSettingsStore: @unchecked Sendable {
    public static let shared = AudioSettingsStore()
    private let userDefaultsKey = "AntigravityAppAudioPreferences"
    private let queue = DispatchQueue(label: "com.antigravity.audiosettings", attributes: .concurrent)
    private var cache: [String: AppAudioPreference] = [:]
    
    private init() {
        loadFromDisk()
    }
    
    private func loadFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return }
        do {
            let decoded = try JSONDecoder().decode([String: AppAudioPreference].self, from: data)
            queue.async(flags: .barrier) {
                self.cache = decoded
            }
        } catch {
            NSLog("[AudioSettingsStore] Failed to load preferences: \(error)")
        }
    }
    
    public func getPreference(for key: String) -> AppAudioPreference? {
        return queue.sync {
            cache[key]
        }
    }
    
    public func savePreference(_ pref: AppAudioPreference, for key: String) {
        queue.async(flags: .barrier) {
            self.cache[key] = pref
            self.persistToDisk()
        }
    }
    
    public func removePreference(for key: String) {
        queue.async(flags: .barrier) {
            self.cache.removeValue(forKey: key)
            self.persistToDisk()
        }
    }
    
    public func clearAll() {
        queue.async(flags: .barrier) {
            self.cache.removeAll()
            self.persistToDisk()
        }
    }
    
    private func persistToDisk() {
        do {
            let data = try JSONEncoder().encode(cache)
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        } catch {
            NSLog("[AudioSettingsStore] Failed to save preferences: \(error)")
        }
    }
}
