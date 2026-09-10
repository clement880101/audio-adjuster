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

/// Configuration for the anti-duck feature.
///
/// The shape of this reflects a measured fact: during a call, macOS applies a linear
/// attenuation of roughly 0.033 (about -30 dB) to every process that is not the call
/// itself — including us. Two consequences follow.
///
/// First, the call app must never be tapped. Its audio is exempt from ducking, but
/// re-rendering it makes it *our* audio, which is then ducked. Measured on a live call:
/// tapping the call engine made the call quieter, not louder.
///
/// Second, countering the duck for other apps means boosting by roughly 1/0.033, far
/// beyond the normal gain range.
public struct AntiDuckPreset: Codable, Equatable, Sendable {

    /// Apps that must never be tapped, because they are the source of the call audio.
    public var protectedBundleIDs: Set<String>

    /// Multiplier applied to other apps while anti-duck is on.
    public var othersBoost: Float

    public init(protectedBundleIDs: Set<String>, othersBoost: Float) {
        self.protectedBundleIDs = protectedBundleIDs
        self.othersBoost = othersBoost
    }

    public static let `default` = AntiDuckPreset(
        protectedBundleIDs: [
            "com.apple.FaceTime",
            // The call engine that actually renders FaceTime audio.
            "com.apple.avconferenced",
            "com.apple.TelephonyUtilities",
        ],
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

    /// True for apps we refuse to tap. Tapping a call engine strips its exemption from
    /// ducking and makes the call quieter, so the slider is refused rather than offered
    /// and then quietly doing harm.
    public func isProtected(_ bundleID: String) -> Bool {
        preset.protectedBundleIDs.contains(bundleID)
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
        guard !isProtected(bundleID) else { return 1.0 }
        let setting = self.setting(for: bundleID)
        if setting.isMuted { return 0 }
        guard isAntiDuckEnabled else { return GainStage.clampGain(setting.gain) }
        return GainStage.clampGain(setting.gain * preset.othersBoost)
    }

    /// True when this app needs a tap: either the user changed it, or anti-duck is on and
    /// would move it away from unity.
    public func requiresChannel(for bundleID: String) -> Bool {
        guard !isProtected(bundleID) else { return false }
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
