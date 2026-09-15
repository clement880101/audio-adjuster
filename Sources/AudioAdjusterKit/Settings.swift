import Foundation

/// Per-application volume state, as chosen by the user.
public struct AppGainSetting: Codable, Equatable, Sendable {
    public var gain: Float
    public var isMuted: Bool

    public init(gain: Float = 1.0, isMuted: Bool = false) {
        self.gain = gain
        self.isMuted = isMuted
    }

    public static let unchanged = AppGainSetting()

    /// True when the app is left exactly as macOS would play it. No tap is created for
    /// apps in this state, so this predicate decides whether we touch an app's audio.
    public var isUnchanged: Bool { self == .unchanged }
}

/// Which processes carry call audio.
///
/// Measured on a live FaceTime call: during a call macOS attenuates every process that is
/// not the call itself by roughly 0.033 (about -30 dB). The call app is exempt — until we
/// tap it, at which point its audio becomes ours and is ducked like anything else.
///
/// So a tapped call engine needs duck compensation simply to sound unchanged. That is not
/// a feature the user chooses; without it, adjusting a call makes it drastically quieter.
/// `DuckServo` measures the attenuation live and `ChannelCoordinator` cancels it.
public struct CallAudioSettings: Codable, Equatable, Sendable {

    public var callEngineBundleIDs: Set<String>

    public init(callEngineBundleIDs: Set<String>) {
        self.callEngineBundleIDs = callEngineBundleIDs
    }

    public static let `default` = CallAudioSettings(
        callEngineBundleIDs: [
            "com.apple.FaceTime",
            // The engine that actually renders FaceTime audio.
            "com.apple.avconferenced",
            "com.apple.TelephonyUtilities",
        ]
    )
}

/// Persistence seam, so the store can be tested without touching real user defaults.
public protocol SettingsBackend: AnyObject {
    func loadData(forKey key: String) -> Data?
    func saveData(_ value: Data?, forKey key: String)
}

extension UserDefaults: SettingsBackend {
    public func loadData(forKey key: String) -> Data? { data(forKey: key) }
    public func saveData(_ value: Data?, forKey key: String) { set(value, forKey: key) }
}

/// In-memory backend for tests.
public final class InMemorySettingsBackend: SettingsBackend {
    private var storage: [String: Data] = [:]
    public init() {}
    public func loadData(forKey key: String) -> Data? { storage[key] }
    public func saveData(_ value: Data?, forKey key: String) { storage[key] = value }
}

/// Owns every user-chosen volume decision and resolves them into the single gain figure
/// the audio path actually applies.
public final class SettingsStore {

    private enum Key {
        static let apps = "apps"
        static let callAudio = "callAudio"
    }

    private let backend: SettingsBackend
    private var apps: [String: AppGainSetting]

    public var callAudio: CallAudioSettings { didSet { persistCallAudio() } }

    public init(backend: SettingsBackend = UserDefaults.standard) {
        self.backend = backend
        let decoder = JSONDecoder()
        self.apps = backend.loadData(forKey: Key.apps)
            .flatMap { try? decoder.decode([String: AppGainSetting].self, from: $0) } ?? [:]
        self.callAudio = backend.loadData(forKey: Key.callAudio)
            .flatMap { try? decoder.decode(CallAudioSettings.self, from: $0) } ?? .default
    }

    public func setting(for bundleID: String) -> AppGainSetting {
        apps[bundleID] ?? .unchanged
    }

    /// True for processes carrying call audio. They are adjustable like anything else,
    /// but their channel is always duck-compensated, because tapping them costs them the
    /// exemption from ducking that they would otherwise have.
    public func isCallEngine(_ bundleID: String) -> Bool {
        callAudio.callEngineBundleIDs.contains(bundleID)
    }

    public func setGain(_ gain: Float, for bundleID: String) {
        var setting = self.setting(for: bundleID)
        setting.gain = GainStage.clampGain(gain)
        update(setting, for: bundleID)
    }

    public func setMuted(_ isMuted: Bool, for bundleID: String) {
        var setting = self.setting(for: bundleID)
        setting.isMuted = isMuted
        update(setting, for: bundleID)
    }

    /// Writes several gains at once, for a balanced drag that moves every app.
    public func setGains(_ gains: [String: Float]) {
        for (bundleID, gain) in gains {
            var setting = self.setting(for: bundleID)
            setting.gain = GainStage.clampGain(gain)
            if setting.isUnchanged {
                apps.removeValue(forKey: bundleID)
            } else {
                apps[bundleID] = setting
            }
        }
        persistApps()
    }

    public func reset(_ bundleID: String) {
        apps.removeValue(forKey: bundleID)
        persistApps()
    }

    /// Bundle IDs the user has actually changed. Apps absent from this list never get a
    /// tap, so nothing about their audio path is altered.
    public var adjustedBundleIDs: [String] {
        apps.filter { !$0.value.isUnchanged }.keys.sorted()
    }

    /// The gain the audio path should apply, folding in mute and the anti-duck preset.
    public func effectiveGain(for bundleID: String) -> Float {
        let setting = self.setting(for: bundleID)
        if setting.isMuted { return 0 }
        return GainStage.clampGain(setting.gain)
    }

    /// True when this app needs a tap: either the user changed it, or anti-duck is on and
    /// would move it away from unity.
    public func requiresChannel(for bundleID: String) -> Bool {
        !setting(for: bundleID).isUnchanged
    }

    private func update(_ setting: AppGainSetting, for bundleID: String) {
        if setting.isUnchanged {
            apps.removeValue(forKey: bundleID)
        } else {
            apps[bundleID] = setting
        }
        persistApps()
    }

    private func persistApps() {
        backend.saveData(try? JSONEncoder().encode(apps), forKey: Key.apps)
    }

    private func persistCallAudio() {
        backend.saveData(try? JSONEncoder().encode(callAudio), forKey: Key.callAudio)
    }
}
