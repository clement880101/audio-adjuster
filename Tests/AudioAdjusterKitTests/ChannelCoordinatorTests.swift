import CoreAudio
import Foundation
import Testing
@testable import AudioAdjusterKit

private let music = "com.apple.Music"
private let faceTime = "com.apple.FaceTime"

private func process(_ bundleID: String, playing: Bool = true, objectID: AudioObjectID = 1) -> AudioProcess {
    AudioProcess(objectIDs: [objectID], pid: 100, bundleID: bundleID, name: bundleID, isPlaying: playing)
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



    @Test("an adjusted call app keeps its channel")
    func callAppKeepsChannel() {
        let store = makeStore()
        store.setGain(1.5, for: faceTime)
        let plan = ChannelCoordinator.plan(processes: [process(faceTime)], existing: [faceTime], settings: store)
        #expect(plan.detach.isEmpty)
        #expect(plan.update == [faceTime: 1.5])
    }

}
