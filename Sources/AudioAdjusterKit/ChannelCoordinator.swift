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
    private var processes: [AudioProcess] = []
    private let log = Logger(subsystem: "com.audioadjuster", category: "coordinator")

    /// Reports a channel that could not be attached, so the UI can show the app as
    /// uncontrolled rather than silently lying about it.
    public var onError: ((String, Error) -> Void)?

    /// Overridable so tests and the probe can supply a device UID without hardware.
    public var outputDeviceUID: () throws -> String = {
        try CoreAudioSystem.deviceUID(CoreAudioSystem.defaultOutputDeviceID())
    }

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
        for (_, channel) in channels { channel.detach() }
        channels.removeAll()
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
            channels[bundleID] = channel
        } catch {
            log.error("could not control \(bundleID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            onError?(bundleID, error)
        }
    }
}
