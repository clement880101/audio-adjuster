import AppKit
import AudioAdjusterKit
import Combine
import CoreAudio
import Foundation

/// Bridges the audio engine to SwiftUI: owns the registry, the settings and the channel
/// coordinator, and republishes their state for the menu bar view.
@MainActor
final class AppModel: ObservableObject {

    @Published private(set) var processes: [AudioProcess] = []
    /// Apps that could not be controlled, so the UI can say so instead of showing a
    /// slider that does nothing.
    @Published private(set) var failures: [String: String] = [:]
    @Published var isAntiDuckEnabled: Bool {
        didSet {
            guard isAntiDuckEnabled != settings.isAntiDuckEnabled else { return }
            settings.isAntiDuckEnabled = isAntiDuckEnabled
            if !isAntiDuckEnabled { coordinator.releaseDuck() }
            coordinator.reconcile()
        }
    }

    private let settings: SettingsStore
    private let system = CoreAudioSystem()
    private let coordinator: ChannelCoordinator
    private lazy var registry = AudioProcessRegistry(source: system, names: RunningAppNameResolver())

    private var refreshTimer: Timer?
    private var duckTimer: Timer?

    /// Live anti-duck state, for the menu bar.
    @Published private(set) var duckCompensation: Float = 1
    @Published private(set) var isCallActive = false
    @Published private(set) var isDuckCalibrated = false
    private var processListListener: AudioObjectPropertyListenerBlock?
    private var outputDeviceListener: AudioObjectPropertyListenerBlock?

    init() {
        let settings = SettingsStore()
        self.settings = settings
        self.coordinator = ChannelCoordinator(settings: settings)
        self.isAntiDuckEnabled = settings.isAntiDuckEnabled

        coordinator.onError = { [weak self] bundleID, error in
            Task { @MainActor in self?.failures[bundleID] = "\(error)" }
        }
        coordinator.onSilenceDetected = { [weak self] bundleID in
            Task { @MainActor in
                // The app has been restored to normal volume; say why rather than letting
                // the slider look like it worked.
                self?.failures[bundleID] = "No audio captured — allow Audio Adjuster under "
                    + "Privacy & Security › Screen & System Audio Recording, then try again."
            }
        }
        registry.onChange = { [weak self] processes in
            Task { @MainActor in self?.apply(processes: processes) }
        }
    }

    func start() {
        refresh()
        // `isRunningOutput` has no change notification of its own, so the playing state is
        // polled. The interval is loose because it only drives list ordering and labels.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Anti-duck compensation can reach 30x, so the window between a call ending and
        // us noticing has to be short. This tick is cheap: property reads and arithmetic.
        duckTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.duckTick() }
        }
        observeProcessList()
        observeDefaultOutputDevice()
    }

    /// Restores every app before the process exits.
    func shutDown() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        duckTimer?.invalidate()
        duckTimer = nil
        coordinator.detachAll()
    }

    private func duckTick() {
        coordinator.tick(processes: processes)
        let active = processes.contains { settings.isProtected($0.bundleID) && $0.isPlaying }
        if active != isCallActive { isCallActive = active }
        if coordinator.duckCompensation != duckCompensation { duckCompensation = coordinator.duckCompensation }
        if coordinator.isDuckCalibrated != isDuckCalibrated { isDuckCalibrated = coordinator.isDuckCalibrated }
    }

    // MARK: - Per-app controls

    func gain(for bundleID: String) -> Float { settings.setting(for: bundleID).gain }
    func isMuted(_ bundleID: String) -> Bool { settings.setting(for: bundleID).isMuted }
    /// Apps we refuse to tap because doing so degrades call audio.
    func isProtected(_ bundleID: String) -> Bool { settings.isProtected(bundleID) }
    func isControlled(_ bundleID: String) -> Bool { coordinator.controlledBundleIDs.contains(bundleID) }
    func failure(for bundleID: String) -> String? { failures[bundleID] }

    func setGain(_ gain: Float, for bundleID: String) {
        // Sliders are linked: the volume one app gains, the others give up. Call engines
        // are excluded because they can never be tapped, so they cannot give or take.
        // Mute is deliberately not balanced - it is the way to silence one app alone.
        let participants = processes.map(\.bundleID).filter { !settings.isProtected($0) }
        var current: [String: Float] = [:]
        for id in participants { current[id] = settings.setting(for: id).gain }
        settings.setGains(Balance.apply(gains: current, changed: bundleID, newGain: gain))
        failures.removeValue(forKey: bundleID)
        coordinator.reconcile()
        objectWillChange.send()
    }

    /// Sum of the gains of every app that can be balanced, shown so the constant total is
    /// visible rather than implied.
    var balanceTotal: Float {
        processes
            .map(\.bundleID)
            .filter { !settings.isProtected($0) }
            .reduce(0) { $0 + settings.setting(for: $1).gain }
    }

    func toggleMute(_ bundleID: String) {
        settings.setMuted(!isMuted(bundleID), for: bundleID)
        failures.removeValue(forKey: bundleID)
        coordinator.reconcile()
        objectWillChange.send()
    }

    /// Returns everything to normal volume and releases every tap.
    func resetAll() {
        for bundleID in settings.adjustedBundleIDs { settings.reset(bundleID) }
        isAntiDuckEnabled = false
        settings.isAntiDuckEnabled = false
        failures.removeAll()
        coordinator.reconcile()
        objectWillChange.send()
    }

    var hasAdjustments: Bool { !settings.adjustedBundleIDs.isEmpty || isAntiDuckEnabled }

    // MARK: - Refresh and observation

    private func refresh() {
        registry.refresh()
        apply(processes: registry.processes)
        // Catches a tap that was granted but yields silence, which would otherwise leave
        // the app muted with no indication why.
        coordinator.auditForSilentTaps(processes: registry.processes)
    }

    private func apply(processes: [AudioProcess]) {
        self.processes = processes
        coordinator.reconcile(processes: processes)
    }

    private func observeProcessList() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        processListListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }

    private func observeDefaultOutputDevice() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Every aggregate device is bound to the old output device and is now invalid.
            Task { @MainActor in self?.coordinator.rebuildForOutputDeviceChange() }
        }
        outputDeviceListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }
}
