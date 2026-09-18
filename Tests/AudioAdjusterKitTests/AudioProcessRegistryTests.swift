import CoreAudio
import Foundation
import Testing
@testable import AudioAdjusterKit

private final class FakeSource: AudioProcessSource {
    var raw: [RawAudioProcess]
    init(_ raw: [RawAudioProcess]) { self.raw = raw }
    func rawProcesses() -> [RawAudioProcess] { raw }
}

/// Resolves a display name from a fixed table, falling back to nil like the real resolver
/// does for processes that are not running applications.
private final class FakeNames: AppNameResolver {
    var table: [String: String]
    init(_ table: [String: String] = [:]) { self.table = table }
    func displayName(pid: pid_t, bundleID: String) -> String? { table[bundleID] }
}

private func raw(
    _ objectID: AudioObjectID,
    pid: pid_t = 100,
    bundleID: String?,
    isRunning: Bool = true,
    isRunningOutput: Bool = true
) -> RawAudioProcess {
    RawAudioProcess(objectID: objectID, pid: pid, bundleID: bundleID, isRunning: isRunning, isRunningOutput: isRunningOutput)
}

@Suite("AudioProcessRegistry")
struct AudioProcessRegistryTests {

    @Test("processes without a bundle ID are dropped")
    func requiresBundleID() {
        let result = AudioProcessRegistry.assemble(
            raw: [raw(1, bundleID: nil), raw(2, bundleID: ""), raw(3, bundleID: "a")],
            excludingPID: 0,
            names: FakeNames()
        )
        #expect(result.map(\.bundleID) == ["a"])
    }

    @Test("our own process is excluded")
    func excludesSelf() {
        let result = AudioProcessRegistry.assemble(
            raw: [raw(1, pid: 42, bundleID: "me"), raw(2, pid: 43, bundleID: "other")],
            excludingPID: 42,
            names: FakeNames()
        )
        #expect(result.map(\.bundleID) == ["other"])
    }

    @Test("a process that has never made a sound is hidden")
    func hidesSilentProcesses() {
        // Core Audio lists around thirty of these; only the audible ones are wanted.
        let result = AudioProcessRegistry.assemble(
            raw: [
                raw(1, pid: 1, bundleID: "com.apple.audiomxd", isRunning: true, isRunningOutput: false),
                raw(2, pid: 2, bundleID: "com.apple.Music", isRunning: false, isRunningOutput: false),
            ],
            excludingPID: 0,
            names: FakeNames(["com.apple.Music": "Music"])
        )
        #expect(result.isEmpty)
    }

    @Test("anything actually making sound is shown, whatever it is")
    func showsAnythingAudible() {
        // If the user can hear it they should be able to turn it down, app or daemon.
        let result = AudioProcessRegistry.assemble(
            raw: [raw(1, bundleID: "com.apple.PowerChime", isRunningOutput: true)],
            excludingPID: 0,
            names: FakeNames(["com.apple.PowerChime": "PowerChime"])
        )
        #expect(result.map(\.name) == ["PowerChime"])
    }

    @Test("an app that has played is remembered once it falls silent")
    func remembersAppsThatHavePlayed() {
        // Otherwise the control vanishes the moment a track ends, which is exactly when
        // the user reaches for it.
        let result = AudioProcessRegistry.assemble(
            raw: [raw(1, bundleID: "com.apple.Music", isRunningOutput: false)],
            excludingPID: 0,
            names: FakeNames(["com.apple.Music": "Music"]),
            hasEverPlayed: ["com.apple.Music"]
        )
        #expect(result.count == 1)
        #expect(result[0].isPlaying == false)
    }

    @Test("a remembered app that quits is dropped")
    func forgetsQuitApps() {
        // No process object means nothing to tap, so the row would be a lie.
        let result = AudioProcessRegistry.assemble(
            raw: [],
            excludingPID: 0,
            names: FakeNames(),
            hasEverPlayed: ["com.apple.Music"]
        )
        #expect(result.isEmpty)
    }

    @Test("playing is remembered across refreshes")
    func registryRemembersAcrossRefreshes() {
        let source = FakeSource([raw(1, bundleID: "com.apple.Music", isRunningOutput: true)])
        let registry = AudioProcessRegistry(
            source: source,
            names: FakeNames(["com.apple.Music": "Music"]),
            ownPID: 0
        )
        registry.refresh()
        #expect(registry.processes.map(\.isPlaying) == [true])

        source.raw = [raw(1, bundleID: "com.apple.Music", isRunningOutput: false)]
        registry.refresh()
        #expect(registry.processes.count == 1)
        #expect(registry.processes[0].isPlaying == false)
    }

    @Test("apps named up front are listed before they ever play")
    func initiallyKnownAppsAreListed() {
        // Apps the user has already set a volume for must stay reachable after a restart.
        let source = FakeSource([raw(1, bundleID: "com.apple.Music", isRunningOutput: false)])
        let registry = AudioProcessRegistry(
            source: source,
            names: FakeNames(["com.apple.Music": "Music"]),
            ownPID: 0,
            initiallyKnown: ["com.apple.Music"]
        )
        registry.refresh()
        #expect(registry.processes.map(\.name) == ["Music"])
    }

    @Test("a daemon that is actually playing is listed anyway")
    func showsPlayingDaemons() {
        let result = AudioProcessRegistry.assemble(
            raw: [raw(1, bundleID: "com.apple.somedaemon", isRunning: true, isRunningOutput: true)],
            excludingPID: 0,
            names: FakeNames()
        )
        #expect(result.count == 1)
        #expect(result[0].isPlaying)
    }

    @Test("several processes of one app become a single entry covering all of them")
    func mergesProcessesOfOneApp() {
        let result = AudioProcessRegistry.assemble(
            raw: [
                raw(1, pid: 10, bundleID: "app", isRunning: true, isRunningOutput: true),
                raw(2, pid: 11, bundleID: "app", isRunning: true, isRunningOutput: false),
            ],
            excludingPID: 0,
            names: FakeNames()
        )
        #expect(result.count == 1)
        #expect(result[0].isPlaying)
        // Both are tapped: leaving one out would let part of the app stay at full volume.
        #expect(result[0].objectIDs == [1, 2])
    }

    @Test("merge order does not matter")
    func mergeIsOrderIndependent() {
        let result = AudioProcessRegistry.assemble(
            raw: [
                raw(2, pid: 11, bundleID: "app", isRunning: true, isRunningOutput: false),
                raw(1, pid: 10, bundleID: "app", isRunning: true, isRunningOutput: true),
            ],
            excludingPID: 0,
            names: FakeNames()
        )
        #expect(result.count == 1)
        #expect(result[0].objectIDs == [1, 2])
        #expect(result[0].isPlaying)
    }

    @Test("the bundle ID is used when no display name is available")
    func fallsBackToBundleID() {
        let result = AudioProcessRegistry.assemble(
            raw: [raw(1, bundleID: "com.example.thing")],
            excludingPID: 0,
            names: FakeNames()
        )
        #expect(result[0].name == "com.example.thing")
    }

    @Test("results are sorted by display name, case-insensitively")
    func sortedByName() {
        let names = FakeNames(["a": "zebra", "b": "Apple", "c": "mango"])
        let result = AudioProcessRegistry.assemble(
            raw: [raw(1, pid: 1, bundleID: "a"), raw(2, pid: 2, bundleID: "b"), raw(3, pid: 3, bundleID: "c")],
            excludingPID: 0,
            names: names
        )
        #expect(result.map(\.name) == ["Apple", "mango", "zebra"])
    }

    @Test("apps making sound are listed before idle ones")
    func playingAppsComeFirst() {
        // The list runs to a dozen or more entries; burying the audible one alphabetically
        // makes changes invisible.
        let names = FakeNames(["a": "Apple", "z": "Zebra"])
        let result = AudioProcessRegistry.assemble(
            raw: [
                raw(1, pid: 1, bundleID: "a", isRunningOutput: false),
                raw(2, pid: 2, bundleID: "z", isRunningOutput: true),
            ],
            excludingPID: 0,
            names: names,
            hasEverPlayed: ["a"]
        )
        #expect(result.map(\.name) == ["Zebra", "Apple"])
    }

    @Test("refresh notifies only when the list actually changes")
    func changeNotification() {
        let source = FakeSource([raw(1, bundleID: "a")])
        let registry = AudioProcessRegistry(source: source, names: FakeNames(), ownPID: 0)
        var notifications = 0
        registry.onChange = { _ in notifications += 1 }

        registry.refresh()
        #expect(notifications == 1)
        #expect(registry.processes.map(\.bundleID) == ["a"])

        registry.refresh()
        #expect(notifications == 1, "an unchanged list must not churn the UI")

        source.raw = [raw(1, bundleID: "a"), raw(2, pid: 101, bundleID: "b")]
        registry.refresh()
        #expect(notifications == 2)
        #expect(registry.processes.map(\.bundleID) == ["a", "b"])
    }
}

@Suite("Process grouping")
struct ProcessGroupingTests {

    @Test("FaceTime's two processes collapse into one entry")
    func faceTimeIsOneEntry() {
        // A call shows up as both FaceTime and avconferenced; two bars for one
        // conversation is wrong, and a tap can cover both process objects at once.
        let result = AudioProcessRegistry.assemble(
            raw: [
                raw(10, pid: 1, bundleID: "com.apple.FaceTime", isRunningOutput: false),
                raw(11, pid: 2, bundleID: "com.apple.avconferenced", isRunningOutput: true),
            ],
            excludingPID: 0,
            names: FakeNames(["com.apple.FaceTime": "FaceTime", "com.apple.avconferenced": "avconferenced"])
        )
        #expect(result.count == 1)
        #expect(result[0].bundleID == "com.apple.FaceTime")
        #expect(result[0].name == "FaceTime")
        // Both processes must be tapped, or half the call stays at full volume.
        #expect(result[0].objectIDs == [10, 11])
    }

    @Test("a group plays when any of its processes does")
    func groupPlaysIfAnyMemberDoes() {
        let result = AudioProcessRegistry.assemble(
            raw: [
                raw(10, pid: 1, bundleID: "com.apple.FaceTime", isRunningOutput: false),
                raw(11, pid: 2, bundleID: "com.apple.avconferenced", isRunningOutput: true),
            ],
            excludingPID: 0,
            names: FakeNames(["com.apple.FaceTime": "FaceTime"])
        )
        #expect(result[0].isPlaying)
    }

    @Test("a helper alone is named for the group, not the helper")
    func helperAloneUsesGroupName() {
        // During a call avconferenced can be audible while FaceTime itself is silent.
        let result = AudioProcessRegistry.assemble(
            raw: [raw(11, pid: 2, bundleID: "com.apple.avconferenced", isRunningOutput: true)],
            excludingPID: 0,
            names: FakeNames()
        )
        #expect(result.count == 1)
        #expect(result[0].bundleID == "com.apple.FaceTime")
        #expect(result[0].name == "FaceTime")
    }

    @Test("the settings key is the group, so one volume covers the call")
    func groupSharesOneSetting() {
        #expect(ProcessGroup.canonicalID(for: "com.apple.avconferenced") == "com.apple.FaceTime")
        #expect(ProcessGroup.canonicalID(for: "com.apple.Music") == "com.apple.Music")
    }

    @Test("a remembered group stays listed after it falls silent")
    func groupIsRemembered() {
        let source = FakeSource([raw(11, pid: 2, bundleID: "com.apple.avconferenced", isRunningOutput: true)])
        let registry = AudioProcessRegistry(source: source, names: FakeNames(), ownPID: 0)
        registry.refresh()
        #expect(registry.processes.map(\.bundleID) == ["com.apple.FaceTime"])

        source.raw = [raw(11, pid: 2, bundleID: "com.apple.avconferenced", isRunningOutput: false)]
        registry.refresh()
        #expect(registry.processes.map(\.bundleID) == ["com.apple.FaceTime"])
        #expect(registry.processes[0].isPlaying == false)
    }
}
