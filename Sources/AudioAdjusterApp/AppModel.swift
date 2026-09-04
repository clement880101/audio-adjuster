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
            coordinator.reconcile()
        }
    }

    private let settings: SettingsStore
    private let system = CoreAudioSystem()
    private let coordinator: ChannelCoordinator
    private lazy var registry = AudioProcessRegistry(source: system, names: RunningAppNameResolver())

    private var refreshTimer: Timer?
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
        observeProcessList()
        observeDefaultOutputDevice()
    }

    /// Restores every app before the process exits.
    func shutDown() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        coordinator.detachAll()
    }

    // MARK: - Per-app controls

    func gain(for bundleID: String) -> Float { settings.setting(for: bundleID).gain }
    func isMuted(_ bundleID: String) -> Bool { settings.setting(for: bundleID).isMuted }
    func isControlled(_ bundleID: String) -> Bool { coordinator.controlledBundleIDs.contains(bundleID) }
    func failure(for bundleID: String) -> String? { failures[bundleID] }

    func setGain(_ gain: Float, for bundleID: String) {
        settings.setGain(gain, for: bundleID)
        failures.removeValue(forKey: bundleID)
        coordinator.reconcile()
        objectWillChange.send()
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
