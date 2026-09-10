import CoreAudio
import Foundation
import os

/// What the channel set must change to match the current settings and process list.
public struct ChannelPlan: Equatable {
    public var attach: [String] = []
    public var update: [String: Float] = [:]
    public var detach: [String] = []
    public var isEmpty: Bool { attach.isEmpty && update.isEmpty && detach.isEmpty }
}

/// Keeps the live set of `AppAudioChannel`s in step with the user's settings and the
/// applications currently making sound.
public final class ChannelCoordinator {

    private let settings: SettingsStore
    private var channels: [String: AppAudioChannel] = [:]
    private var audits: [String: SilenceAudit] = [:]
    /// Telemetry is read in exactly one place, because reading resets the peak.
    private var sawAudio: [String: Bool] = [:]
    private var lastFrames: [String: UInt64] = [:]

    private var servo = DuckServo()
    private var observer: AppAudioChannel?
    private var processes: [AudioProcess] = []
    private let log = Logger(subsystem: "com.audioadjuster", category: "coordinator")

    /// Reports a channel that could not be attached, so the UI can show the app as
    /// uncontrolled rather than silently lying about it.
    public var onError: ((String, Error) -> Void)?

    /// Reports a channel released because its tap delivered only silence.
    public var onSilenceDetected: ((String) -> Void)?

    /// Overridable so tests and the probe can supply a device UID without hardware.
    public var outputDeviceUID: () throws -> String = {
        try CoreAudioSystem.deviceUID(CoreAudioSystem.defaultOutputDeviceID())
    }

    /// Our own audio process object, needed to observe what we are putting on the device.
    /// Only exists while we are actually rendering.
    public var ownAudioProcessObjectID: () -> AudioObjectID? = {
        let pid = ProcessInfo.processInfo.processIdentifier
        return CoreAudioSystem().rawProcesses().first { $0.pid == pid }?.objectID
    }

    /// Current anti-duck compensation, for display.
    public var duckCompensation: Float { servo.compensation }
    public var isDuckCalibrated: Bool { servo.hasCalibrated }

    public init(settings: SettingsStore) {
        self.settings = settings
    }

    public var controlledBundleIDs: Set<String> { Set(channels.keys) }

    /// Decides what to change. Pure, so the rules are testable without Core Audio.
    ///
    /// A channel is attached only once an app is actually producing sound, but an
    /// existing channel is kept while the app remains in the list even if it falls
    /// briefly silent — `isRunningOutput` flickers between tracks, and tearing the graph
    /// down and back up each time would be audible.
    public static func plan(
        processes: [AudioProcess],
        existing: Set<String>,
        settings: SettingsStore
    ) -> ChannelPlan {
        var plan = ChannelPlan()
        let present = Set(processes.map(\.bundleID))

        for process in processes {
            let wanted = settings.requiresChannel(for: process.bundleID)
            let has = existing.contains(process.bundleID)

            if wanted, has {
                plan.update[process.bundleID] = settings.effectiveGain(for: process.bundleID)
            } else if wanted, process.isPlaying {
                plan.attach.append(process.bundleID)
            } else if !wanted, has {
                plan.detach.append(process.bundleID)
            }
        }

        // An app that quit leaves no process object, so its channel has nothing to tap.
        for bundleID in existing where !present.contains(bundleID) {
            plan.detach.append(bundleID)
        }

        plan.attach.sort()
        plan.detach.sort()
        return plan
    }

    /// Recomputes and applies the plan. Safe to call on every settings or process change.
    public func reconcile(processes: [AudioProcess]) {
        self.processes = processes
        let plan = ChannelCoordinator.plan(
            processes: processes,
            existing: controlledBundleIDs,
            settings: settings
        )
        guard !plan.isEmpty else { return }

        for bundleID in plan.detach {
            channels.removeValue(forKey: bundleID)?.detach()
            audits.removeValue(forKey: bundleID)
            sawAudio.removeValue(forKey: bundleID)
            lastFrames.removeValue(forKey: bundleID)
            renderedPeaks.removeValue(forKey: bundleID)
        }
        for (bundleID, gain) in plan.update {
            channels[bundleID]?.setGain(gain)
        }
        for bundleID in plan.attach {
            attach(bundleID: bundleID)
        }
    }

    /// Re-applies the plan against the process list we already have. Used when settings
    /// change without the process list moving.
    public func reconcile() {
        reconcile(processes: processes)
    }

    /// Rebuilds every channel. Aggregate devices are bound to a specific output device,
    /// so they are all invalid once the default output changes (AirPods connecting, say).
    public func rebuildForOutputDeviceChange() {
        let controlled = channels.keys.sorted()
        for bundleID in controlled {
            channels.removeValue(forKey: bundleID)?.detach()
        }
        reconcile()
    }

    /// Releases every channel, restoring all apps to their normal audio path.
    public func detachAll() {
        releaseDuck()
        for (_, channel) in channels { channel.detach() }
        channels.removeAll()
        audits.removeAll()
        sawAudio.removeAll()
        lastFrames.removeAll()
        renderedPeaks.removeAll()
    }

    /// Releases any channel whose tap is delivering silence while its app is playing.
    ///
    /// Without the audio-capture permission a tap succeeds but yields zeros, and because
    /// the tap also mutes the app, the app would simply go quiet. Releasing the channel
    /// restores it. Call this on a regular tick.
    public func auditForSilentTaps(processes: [AudioProcess]) {
        for (bundleID, _) in channels {
            let isPlaying = processes.first { $0.bundleID == bundleID }?.isPlaying ?? false
            // Telemetry is gathered by tick(); using its accumulated view avoids two
            // consumers racing to reset the same peak.
            let heardAudio = sawAudio[bundleID] ?? false
            sawAudio[bundleID] = false
            var audit = audits[bundleID] ?? SilenceAudit()
            let hasFailed = audit.record(
                frames: lastFrames[bundleID] ?? 0,
                peak: heardAudio ? 1 : 0,
                isPlaying: isPlaying
            )
            audits[bundleID] = audit

            guard hasFailed else { continue }
            log.error("releasing \(bundleID, privacy: .public): tap delivered only silence")
            channels.removeValue(forKey: bundleID)?.detach()
            audits.removeValue(forKey: bundleID)
            onSilenceDetected?(bundleID)
        }
    }

    // MARK: - Anti-duck

    /// Reads channel telemetry and updates anti-duck compensation.
    ///
    /// Must be called often — the compensation can be 30x, so the gap between a call
    /// ending and us noticing is the window in which audio would be far too loud.
    public func tick(processes: [AudioProcess]) {
        for (bundleID, channel) in channels {
            let statistics = channel.readStatistics()
            if statistics.peak > 0 { sawAudio[bundleID] = true }
            lastFrames[bundleID] = statistics.frames
            renderedPeaks[bundleID] = statistics.peak
        }
        updateDuckCompensation(processes: processes)
    }

    private var renderedPeaks: [String: Float] = [:]

    private func updateDuckCompensation(processes: [AudioProcess]) {
        // A call engine actually producing audio is the only condition under which there
        // is a duck to cancel.
        let isCallActive = settings.isAntiDuckEnabled && processes.contains {
            settings.isProtected($0.bundleID) && $0.isPlaying
        }

        guard isCallActive else {
            if servo.compensation != 1 || observer != nil { releaseDuck() }
            return
        }

        attachObserverIfNeeded()
        let renderedPeak = renderedPeaks.values.max() ?? 0
        let observedPeak = observer?.readStatistics().inputPeak ?? 0
        servo.update(renderedPeak: renderedPeak, observedPeak: observedPeak, isCallActive: true)
        applyCompensation()
    }

    /// Attaches an unmuted, silent tap on ourselves, used purely to measure what our own
    /// output actually sounds like at the device after the system has ducked it.
    private func attachObserverIfNeeded() {
        guard observer == nil, !channels.isEmpty else { return }
        guard let objectID = ownAudioProcessObjectID() else { return }
        // Unmuted so it changes nothing, gain 0 so it contributes silence.
        let channel = AppAudioChannel(
            bundleID: "self-observer",
            processObjectID: objectID,
            gain: 0,
            options: .init(muteBehavior: .unmuted, isPrivate: true)
        )
        do {
            try channel.attach(outputDeviceUID: try outputDeviceUID())
            observer = channel
        } catch {
            log.error("anti-duck calibration unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func applyCompensation() {
        for (bundleID, channel) in channels {
            channel.setCompensation(settings.isProtected(bundleID) ? 1 : servo.compensation)
        }
    }

    /// Drops compensation to unity everywhere and tears down the observer.
    public func releaseDuck() {
        servo.release()
        for (_, channel) in channels { channel.setCompensation(1) }
        observer?.detach()
        observer = nil
    }

    private func attach(bundleID: String) {
        guard let process = processes.first(where: { $0.bundleID == bundleID }) else { return }
        let channel = AppAudioChannel(
            bundleID: bundleID,
            processObjectID: process.objectID,
            gain: settings.effectiveGain(for: bundleID)
        )
        do {
            let uid = try outputDeviceUID()
            try channel.attach(outputDeviceUID: uid)
            channel.setCompensation(settings.isProtected(bundleID) ? 1 : servo.compensation)
            channels[bundleID] = channel
            audits[bundleID] = SilenceAudit()
            sawAudio[bundleID] = false
        } catch {
            log.error("could not control \(bundleID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            onError?(bundleID, error)
        }
    }
}
