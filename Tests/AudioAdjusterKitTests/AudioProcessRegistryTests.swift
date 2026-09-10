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

    @Test("a silent system daemon is hidden")
    func hidesIdleDaemons() {
        // No running-application entry, so this is a daemon like audiomxd rather than an
        // app the user would want a slider for.
        let result = AudioProcessRegistry.assemble(
            raw: [raw(1, bundleID: "com.apple.audiomxd", isRunning: true, isRunningOutput: false)],
            excludingPID: 0,
            names: FakeNames()
        )
        #expect(result.isEmpty)
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

    @Test("an open app is listed while silent, marked not playing")
    func silentAppIsListed() {
        // isRunning is 0 for an idle Music, so the running-application entry is what
        // keeps it in the list.
        let result = AudioProcessRegistry.assemble(
            raw: [raw(1, bundleID: "com.apple.Music", isRunning: false, isRunningOutput: false)],
            excludingPID: 0,
            names: FakeNames(["com.apple.Music": "Music"])
        )
        #expect(result.count == 1)
        #expect(result[0].isPlaying == false)
        #expect(result[0].name == "Music")
    }

    @Test("duplicate bundle IDs collapse, preferring the instance making sound")
    func dedupePrefersPlaying() {
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
        #expect(result[0].objectID == 1)
    }

    @Test("dedupe order does not matter")
    func dedupeIsOrderIndependent() {
        let result = AudioProcessRegistry.assemble(
            raw: [
                raw(2, pid: 11, bundleID: "app", isRunning: true, isRunningOutput: false),
                raw(1, pid: 10, bundleID: "app", isRunning: true, isRunningOutput: true),
            ],
            excludingPID: 0,
            names: FakeNames()
        )
        #expect(result.count == 1)
        #expect(result[0].objectID == 1)
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
            names: names
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
