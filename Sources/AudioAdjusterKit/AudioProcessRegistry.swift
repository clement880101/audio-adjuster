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
            // Without a bundle ID there is nothing stable to key a setting to.
            guard let bundleID = entry.bundleID, !bundleID.isEmpty else { continue }
            // Tapping ourselves would feed our own output back into our input.
            guard entry.pid != ownPID else { continue }
            guard entry.isRunning || entry.isRunningOutput else { continue }

            let process = AudioProcess(
                objectID: entry.objectID,
                pid: entry.pid,
                bundleID: bundleID,
                name: names.displayName(pid: entry.pid, bundleID: bundleID) ?? bundleID,
                isPlaying: entry.isRunningOutput
            )

            // An app can own several audio process objects (helpers, plug-in hosts). Keep
            // the one actually producing sound, since that is the one worth tapping.
            if let existing = byBundleID[bundleID], existing.isPlaying, !process.isPlaying {
                continue
            }
            byBundleID[bundleID] = process
        }

        return byBundleID.values.sorted {
            let byName = $0.name.localizedCaseInsensitiveCompare($1.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return $0.bundleID < $1.bundleID
        }
    }
}
