import CoreAudio
import Foundation

/// Publishes the list of applications eligible for a volume slider.
public final class AudioProcessRegistry {

    private let source: AudioProcessSource
    private let names: AppNameResolver
    private let ownPID: pid_t

    /// Every app seen producing audio since launch. An app that falls silent stays on the
    /// list, because a volume control you can only reach while a sound is playing is
    /// unusable — by the time you have found it, the thing you wanted to turn down has
    /// finished.
    private var hasEverPlayed: Set<String>

    public private(set) var processes: [AudioProcess] = []

    /// Called after `refresh()` changes the list.
    public var onChange: (([AudioProcess]) -> Void)?

    /// - Parameter initiallyKnown: apps to list from the start, even before they make a
    ///   sound. Used for apps the user has already adjusted, so their settings remain
    ///   reachable across a restart.
    public init(
        source: AudioProcessSource,
        names: AppNameResolver,
        ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        initiallyKnown: Set<String> = []
    ) {
        self.source = source
        self.names = names
        self.ownPID = ownPID
        self.hasEverPlayed = initiallyKnown
    }

    public func refresh() {
        let raw = source.rawProcesses()
        for entry in raw where entry.isRunningOutput {
            if let bundleID = entry.bundleID, !bundleID.isEmpty { hasEverPlayed.insert(bundleID) }
        }
        let updated = AudioProcessRegistry.assemble(
            raw: raw,
            excludingPID: ownPID,
            names: names,
            hasEverPlayed: hasEverPlayed
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
        names: AppNameResolver,
        hasEverPlayed: Set<String> = []
    ) -> [AudioProcess] {
        var byBundleID: [String: AudioProcess] = [:]

        for entry in raw {
            // Without a bundle ID there is nothing stable to key a setting to. This also
            // excludes command-line audio tools, which have no bundle identifier.
            guard let bundleID = entry.bundleID, !bundleID.isEmpty else { continue }
            // Tapping ourselves would feed our own output back into our input.
            guard entry.pid != ownPID else { continue }

            // Only things that actually make sound. Core Audio lists around thirty
            // processes, most of them daemons holding an audio client without ever being
            // audible, and listing those buries the handful that matter.
            //
            // Having made a sound earlier counts: an app keeps its place after it goes
            // quiet, so its volume stays adjustable between tracks or before it starts.
            //
            // `isRunning` is no help here — it means "has an audio client", not "is
            // audible", and is 0 for an idle Music.
            guard entry.isRunningOutput || hasEverPlayed.contains(bundleID) else { continue }

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
