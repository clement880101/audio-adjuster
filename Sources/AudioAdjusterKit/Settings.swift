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

/// The gain preset applied when anti-duck is switched on.
///
/// macOS ducks *other* audio during a call, so countering it means pushing everything
/// else back up, and optionally pulling the call app down so the mix still balances.
public struct AntiDuckPreset: Codable, Equatable, Sendable {
    /// Apps whose calls trigger the system's ducking.
    public var callAppBundleIDs: Set<String>
    /// Multiplier applied to the call app itself.
    public var callAppGain: Float
    /// Multiplier applied to every other app, to undo the system's duck.
    public var othersBoost: Float

    public init(callAppBundleIDs: Set<String>, callAppGain: Float, othersBoost: Float) {
        self.callAppBundleIDs = callAppBundleIDs
        self.callAppGain = callAppGain
        self.othersBoost = othersBoost
    }

    public static let `default` = AntiDuckPreset(
        callAppBundleIDs: ["com.apple.FaceTime"],
        callAppGain: 0.8,
        othersBoost: 1.6
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
        static let preset = "antiDuckPreset"
        static let antiDuckEnabled = "antiDuckEnabled"
    }

    private let backend: SettingsBackend
    private var apps: [String: AppGainSetting]

    public var preset: AntiDuckPreset { didSet { persistPreset() } }
    public var isAntiDuckEnabled: Bool { didSet { persistAntiDuckEnabled() } }

    public init(backend: SettingsBackend = UserDefaults.standard) {
        self.backend = backend
        let decoder = JSONDecoder()
        self.apps = backend.loadData(forKey: Key.apps)
            .flatMap { try? decoder.decode([String: AppGainSetting].self, from: $0) } ?? [:]
        self.preset = backend.loadData(forKey: Key.preset)
            .flatMap { try? decoder.decode(AntiDuckPreset.self, from: $0) } ?? .default
        self.isAntiDuckEnabled = backend.loadData(forKey: Key.antiDuckEnabled)
            .flatMap { try? decoder.decode(Bool.self, from: $0) } ?? false
    }

    public func setting(for bundleID: String) -> AppGainSetting {
        apps[bundleID] ?? .unchanged
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
        guard isAntiDuckEnabled else { return GainStage.clampGain(setting.gain) }
        let multiplier = preset.callAppBundleIDs.contains(bundleID)
            ? preset.callAppGain
            : preset.othersBoost
        return GainStage.clampGain(setting.gain * multiplier)
    }

    /// True when this app needs a tap: either the user changed it, or anti-duck is on and
    /// would move it away from unity.
    public func requiresChannel(for bundleID: String) -> Bool {
        if !setting(for: bundleID).isUnchanged { return true }
        return isAntiDuckEnabled && effectiveGain(for: bundleID) != 1.0
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

    private func persistPreset() {
        backend.saveData(try? JSONEncoder().encode(preset), forKey: Key.preset)
    }

    private func persistAntiDuckEnabled() {
        backend.saveData(try? JSONEncoder().encode(isAntiDuckEnabled), forKey: Key.antiDuckEnabled)
    }
}
