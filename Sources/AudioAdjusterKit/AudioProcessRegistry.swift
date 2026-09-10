import CoreAudio
import Foundation

/// Publishes the list of applications eligible for a volume slider.
public final class AudioProcessRegistry {

    private let source: AudioProcessSource
    private let names: AppNameResolver
    private let ownPID: pid_t

    public private(set) var processes: [AudioProcess] = []

    /// Called after `refresh()` changes the list.
    public var onChange: (([AudioProcess]) -> Void)?

    public init(source: AudioProcessSource, names: AppNameResolver, ownPID: pid_t = ProcessInfo.processInfo.processIdentifier) {
        self.source = source
        self.names = names
        self.ownPID = ownPID
    }

    public func refresh() {
        let updated = AudioProcessRegistry.assemble(
            raw: source.rawProcesses(),
            excludingPID: ownPID,
            names: names
        )
        guard updated != processes else { return }
        processes = updated
        onChange?(updated)
    }

    /// Turns Core Audio's raw process list into the displayable list.
    ///
    /// Pure and static so the filtering rules can be tested without Core Audio.
    public static func assemble(
        raw: [RawAudioProcess],
        excludingPID ownPID: pid_t,
        names: AppNameResolver
    ) -> [AudioProcess] {
        var byBundleID: [String: AudioProcess] = [:]

        for entry in raw {
            // Without a bundle ID there is nothing stable to key a setting to. This also
            // excludes command-line audio tools, which have no bundle identifier.
            guard let bundleID = entry.bundleID, !bundleID.isEmpty else { continue }
            // Tapping ourselves would feed our own output back into our input.
            guard entry.pid != ownPID else { continue }

            // Core Audio lists around thirty processes and most are system daemons that
            // hold an audio client without ever being something a person wants a volume
            // slider for — loginwindow, universalaccessd, PowerChime, SiriNCService. Many
            // of those do have a running-application entry, so merely having one is not
            // enough to tell them apart from real apps.
            //
            // Activation policy is: an ordinary app has a Dock icon, an agent or daemon
            // does not. Anything actually producing sound is shown regardless, since the
            // user can hear it and will want to control it whatever it is.
            //
            // `isRunning` here means "has an active audio client", not "is open", so it is
            // 0 for an idle Music or Firefox and cannot be used to decide this.
            let resolved = names.resolve(pid: entry.pid, bundleID: bundleID)
            guard entry.isRunningOutput || resolved?.isRegularApp == true else { continue }

            let process = AudioProcess(
                objectID: entry.objectID,
                pid: entry.pid,
                bundleID: bundleID,
                name: resolved?.name ?? bundleID,
                isPlaying: entry.isRunningOutput
            )

            // An app can own several audio process objects (helpers, plug-in hosts). Keep
            // the one actually producing sound, since that is the one worth tapping.
            if let existing = byBundleID[bundleID], existing.isPlaying, !process.isPlaying {
                continue
            }
            byBundleID[bundleID] = process
        }

        // Apps actually making sound come first. The list runs to a dozen or more entries,
        // and the ones worth adjusting are the ones you can hear.
        return byBundleID.values.sorted {
            if $0.isPlaying != $1.isPlaying { return $0.isPlaying }
            let byName = $0.name.localizedCaseInsensitiveCompare($1.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return $0.bundleID < $1.bundleID
        }
    }
}
