import AppKit
import AudioAdjusterKit
import Combine
import CoreAudio
import Foundation
import os

/// Bridges the audio engine to SwiftUI: owns the registry, the settings and the channel
/// coordinator, and republishes their state for the menu bar view.
@MainActor
final class AppModel: ObservableObject {

    @Published private(set) var processes: [AudioProcess] = []
    /// Apps that could not be controlled, so the UI can say so instead of showing a
    /// slider that does nothing.
    @Published private(set) var failures: [String: String] = [:]

    /// Shared so the app delegate can start and stop it without depending on a view
    /// having appeared first.
    static let shared = AppModel()

    private let settings: SettingsStore
    private let system = CoreAudioSystem()
    private let coordinator: ChannelCoordinator
    private lazy var registry = AudioProcessRegistry(
        source: system,
        names: RunningAppNameResolver(),
        // Apps the user has already set a volume for stay listed across a restart, so
        // their setting remains reachable without waiting for them to play again.
        initiallyKnown: Set(settings.adjustedBundleIDs)
    )

    private var refreshTimer: Timer?
    private var duckTimer: Timer?
    private var hasStarted = false
    private let log = Logger(subsystem: "com.audioadjuster", category: "model")


    /// True while a call is in progress. Call rows are duck-compensated then.
    @Published private(set) var isCallActive = false

    /// When on, raising one app lowers the others; when off, bars move independently.
    @Published var isLinked: Bool {
        didSet {
            guard isLinked != settings.isLinked else { return }
            settings.isLinked = isLinked
        }
    }
    private var processListListener: AudioObjectPropertyListenerBlock?
    private var outputDeviceListener: AudioObjectPropertyListenerBlock?

    init() {
        let settings = SettingsStore()
        self.settings = settings
        self.coordinator = ChannelCoordinator(settings: settings)
        self.isLinked = settings.isLinked

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
        guard !hasStarted else { return }
        hasStarted = true
        refresh()
        // `isRunningOutput` has no change notification of its own, so whether an app is
        // currently making sound has to be polled.
        refreshTimer = schedule(every: 1.0) { [weak self] in self?.refresh() }
        // Anti-duck compensation can reach 30x, so the window between a call ending and
        // us noticing has to be short. This tick is cheap: property reads and arithmetic.
        duckTimer = schedule(every: 0.2) { [weak self] in self?.duckTick() }
        observeProcessList()
        observeDefaultOutputDevice()
    }

    /// Restores every app before the process exits.
    func shutDown() {
        hasStarted = false
        refreshTimer?.invalidate()
        refreshTimer = nil
        duckTimer?.invalidate()
        duckTimer = nil
        coordinator.detachAll()
    }

    private func duckTick() {
        coordinator.tick(processes: processes)
        let active = processes.contains { settings.isCallEngine($0.bundleID) && $0.isPlaying }
        if active != isCallActive { isCallActive = active }
    }

    // MARK: - Per-app controls

    func gain(for bundleID: String) -> Float { settings.setting(for: bundleID).gain }
    func isMuted(_ bundleID: String) -> Bool { settings.setting(for: bundleID).isMuted }
    /// True for processes carrying call audio. Adjustable, but always duck-compensated.
    func isCallEngine(_ bundleID: String) -> Bool { settings.isCallEngine(bundleID) }
    func isControlled(_ bundleID: String) -> Bool { coordinator.controlledBundleIDs.contains(bundleID) }
    func failure(for bundleID: String) -> String? { failures[bundleID] }

    func setGain(_ gain: Float, for bundleID: String) {
        if isLinked {
            // The volume one app gains, the others give up. Mute is deliberately never
            // balanced — it stays the way to silence one app without moving anything else.
            var current: [String: Float] = [:]
            for id in processes.map(\.bundleID) { current[id] = settings.setting(for: id).gain }
            settings.setGains(Balance.apply(gains: current, changed: bundleID, newGain: gain))
        } else {
            settings.setGain(gain, for: bundleID)
        }
        failures.removeValue(forKey: bundleID)
        coordinator.reconcile()
        objectWillChange.send()
    }

    /// Sum of the gains of every app that can be balanced, shown so the constant total is
    /// visible rather than implied.
    var balanceTotal: Float {
        processes
            .map(\.bundleID)
            .reduce(0) { $0 + settings.setting(for: $1).gain }
    }

    func toggleMute(_ bundleID: String) {
        settings.setMuted(!isMuted(bundleID), for: bundleID)
        failures.removeValue(forKey: bundleID)
        coordinator.reconcile()
        objectWillChange.send()
    }

    /// Returns every app to 100%, unmutes everything, and releases every tap.
    func resetAll() {
        for bundleID in settings.adjustedBundleIDs { settings.reset(bundleID) }
        failures.removeAll()
        coordinator.reconcile()
        objectWillChange.send()
    }

    var hasAdjustments: Bool { !settings.adjustedBundleIDs.isEmpty }

    // MARK: - Refresh and observation

    /// Schedules a repeating timer in `.common` modes.
    ///
    /// `Timer.scheduledTimer` installs into the default run loop mode only, and AppKit
    /// switches to event tracking while a menu bar popover is open — so a default-mode
    /// timer stops firing exactly when the user is looking at the list.
    private func schedule(every interval: TimeInterval, _ body: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor in body() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    /// Refreshes immediately, for when the popover opens.
    func refreshNow() {
        DebugLog.write("VIEW popover opened")
        refresh()
    }

    private func refresh() {
        registry.refresh()
        apply(processes: registry.processes)
        // Catches a tap that was granted but yields silence, which would otherwise leave
        // the app muted with no indication why.
        coordinator.auditForSilentTaps(processes: registry.processes)
    }

    private func apply(processes: [AudioProcess]) {
        if processes != self.processes {
            DebugLog.write("MODEL list changed -> " + processes.map {
                "\($0.name)\($0.isPlaying ? "*" : "")"
            }.joined(separator: ", "))
        }
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
