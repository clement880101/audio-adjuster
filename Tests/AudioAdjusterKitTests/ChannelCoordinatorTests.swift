import CoreAudio
import Foundation
import Testing
@testable import AudioAdjusterKit

private let music = "com.apple.Music"
private let faceTime = "com.apple.FaceTime"

private func process(_ bundleID: String, playing: Bool = true, objectID: AudioObjectID = 1) -> AudioProcess {
    AudioProcess(objectID: objectID, pid: 100, bundleID: bundleID, name: bundleID, isPlaying: playing)
}

private func makeStore() -> SettingsStore {
    SettingsStore(backend: InMemorySettingsBackend())
}

@Suite("ChannelCoordinator.plan")
struct ChannelCoordinatorPlanTests {

    @Test("apps at their default volume are left alone entirely")
    func untouchedAppsAreNotTapped() {
        let plan = ChannelCoordinator.plan(processes: [process(music)], existing: [], settings: makeStore())
        #expect(plan.isEmpty)
    }

    @Test("an adjusted app that is playing gets a channel")
    func attachesPlayingAdjustedApp() {
        let store = makeStore()
        store.setGain(0.5, for: music)
        let plan = ChannelCoordinator.plan(processes: [process(music)], existing: [], settings: store)
        #expect(plan.attach == [music])
    }

    @Test("an adjusted app that is silent is not tapped until it plays")
    func waitsForAudioBeforeAttaching() {
        let store = makeStore()
        store.setGain(0.5, for: music)
        let plan = ChannelCoordinator.plan(processes: [process(music, playing: false)], existing: [], settings: store)
        #expect(plan.attach.isEmpty)
        #expect(plan.isEmpty)
    }

    @Test("an existing channel receives the new effective gain")
    func updatesExistingChannel() {
        let store = makeStore()
        store.setGain(0.25, for: music)
        let plan = ChannelCoordinator.plan(processes: [process(music)], existing: [music], settings: store)
        #expect(plan.update == [music: 0.25])
        #expect(plan.attach.isEmpty)
    }

    @Test("a channel is kept while its app falls briefly silent")
    func doesNotFlapOnSilence() {
        let store = makeStore()
        store.setGain(0.25, for: music)
        // isRunningOutput drops between tracks; tearing the graph down would be audible.
        let plan = ChannelCoordinator.plan(processes: [process(music, playing: false)], existing: [music], settings: store)
        #expect(plan.detach.isEmpty)
        #expect(plan.update == [music: 0.25])
    }

    @Test("returning an app to unity releases its channel")
    func releasesOnReturnToUnity() {
        let store = makeStore()
        let plan = ChannelCoordinator.plan(processes: [process(music)], existing: [music], settings: store)
        #expect(plan.detach == [music])
    }

    @Test("a quit app's channel is released")
    func releasesVanishedApp() {
        let store = makeStore()
        store.setGain(0.5, for: music)
        let plan = ChannelCoordinator.plan(processes: [], existing: [music], settings: store)
        #expect(plan.detach == [music])
    }

    @Test("muting an app attaches a channel, since silence must be rendered")
    func muteNeedsAChannel() {
        let store = makeStore()
        store.setMuted(true, for: music)
        let plan = ChannelCoordinator.plan(processes: [process(music)], existing: [], settings: store)
        #expect(plan.attach == [music])
    }

    @Test("anti-duck attaches other apps but never the call app")
    func antiDuckAttachesEverythingButTheCall() {
        let store = makeStore()
        store.isAntiDuckEnabled = true
        let plan = ChannelCoordinator.plan(
            processes: [process(music, objectID: 1), process(faceTime, objectID: 2)],
            existing: [],
            settings: store
        )
        #expect(plan.attach == [music])
    }

    @Test("switching anti-duck off releases the channels it created")
    func antiDuckOffReleases() {
        let store = makeStore()
        let plan = ChannelCoordinator.plan(
            processes: [process(music, objectID: 1), process("com.apple.Podcasts", objectID: 2)],
            existing: [music, "com.apple.Podcasts"],
            settings: store
        )
        #expect(plan.detach == [music, "com.apple.Podcasts"])
        #expect(plan.update.isEmpty)
    }

    @Test("an existing channel on a call app is released")
    func releasesProtectedApp() {
        let store = makeStore()
        // Settings written before the app was protected must not keep a tap alive.
        store.setGain(2.0, for: faceTime)
        let plan = ChannelCoordinator.plan(processes: [process(faceTime)], existing: [faceTime], settings: store)
        #expect(plan.detach == [faceTime])
    }

    @Test("anti-duck leaves an app the user muted at silence")
    func antiDuckKeepsMuteSilent() {
        let store = makeStore()
        store.setMuted(true, for: music)
        store.isAntiDuckEnabled = true
        let plan = ChannelCoordinator.plan(processes: [process(music)], existing: [music], settings: store)
        #expect(plan.update == [music: 0])
    }
}
