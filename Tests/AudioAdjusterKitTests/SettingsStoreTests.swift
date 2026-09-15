import Foundation
import Testing
@testable import AudioAdjusterKit

private let faceTime = "com.apple.FaceTime"
private let music = "com.apple.Music"
private let music2 = "com.spotify.client"

private func makeStore() -> (SettingsStore, InMemorySettingsBackend) {
    let backend = InMemorySettingsBackend()
    return (SettingsStore(backend: backend), backend)
}

@Suite("SettingsStore")
struct SettingsStoreTests {

    @Test("an untouched app reports unity gain and no channel")
    func defaultsAreTransparent() {
        let (store, _) = makeStore()
        #expect(store.setting(for: music) == .unchanged)
        #expect(store.effectiveGain(for: music) == 1.0)
        #expect(store.requiresChannel(for: music) == false)
    }

    @Test("setting a gain records it and requires a channel")
    func settingGain() {
        let (store, _) = makeStore()
        store.setGain(0.4, for: music)
        #expect(store.effectiveGain(for: music) == 0.4)
        #expect(store.requiresChannel(for: music))
        #expect(store.adjustedBundleIDs == [music])
    }

    @Test("gain is clamped on the way in")
    func gainClamped() {
        let (store, _) = makeStore()
        store.setGain(-1, for: music)
        #expect(store.effectiveGain(for: music) == 0)
        store.setGain(50, for: music)
        #expect(store.effectiveGain(for: music) == GainStage.maxGain)
    }

    @Test("mute overrides gain")
    func muteWins() {
        let (store, _) = makeStore()
        store.setGain(0.8, for: music)
        store.setMuted(true, for: music)
        #expect(store.effectiveGain(for: music) == 0)
    }

    @Test("returning an app to unity drops it from the adjusted list")
    func returningToUnityReleasesTheApp() {
        let (store, _) = makeStore()
        store.setGain(0.4, for: music)
        store.setGain(1.0, for: music)
        // Nothing to apply means no tap, which means the app's audio path is untouched.
        #expect(store.adjustedBundleIDs.isEmpty)
        #expect(store.requiresChannel(for: music) == false)
    }

    @Test("reset clears an app")
    func reset() {
        let (store, _) = makeStore()
        store.setMuted(true, for: music)
        store.reset(music)
        #expect(store.setting(for: music) == .unchanged)
    }


    @Test("gain stays within the supported range")
    func gainStaysClamped() {
        let (store, _) = makeStore()
        store.setGain(GainStage.maxGain, for: music)
        #expect(store.effectiveGain(for: music) == GainStage.maxGain)
    }

    @Test("the call app is adjustable like anything else")
    func callAppIsAdjustable() {
        let (store, _) = makeStore()
        #expect(store.isCallEngine("com.apple.avconferenced"))
        #expect(store.isCallEngine(faceTime))
        // Its channel is always duck-compensated, which is what makes the slider behave;
        // the gain itself is ordinary.
        store.setGain(1.5, for: "com.apple.avconferenced")
        #expect(store.effectiveGain(for: "com.apple.avconferenced") == 1.5)
        #expect(store.requiresChannel(for: "com.apple.avconferenced"))
    }




    @Test("only an app the user has changed needs a channel")
    func onlyChangedAppsNeedChannels() {
        let (store, _) = makeStore()
        #expect(store.requiresChannel(for: music) == false)
        store.setGain(0.5, for: music)
        #expect(store.requiresChannel(for: music))
    }


    @Test("settings survive a restart")
    func persistence() {
        let backend = InMemorySettingsBackend()
        let first = SettingsStore(backend: backend)
        first.setGain(0.3, for: music)
        first.setMuted(true, for: music2)
        first.callAudio = CallAudioSettings(callEngineBundleIDs: ["x"])

        let reloaded = SettingsStore(backend: backend)
        #expect(reloaded.setting(for: music).gain == 0.3)
        #expect(reloaded.setting(for: music2).isMuted)
        #expect(reloaded.callAudio.callEngineBundleIDs == ["x"])
    }

    @Test("corrupt stored data falls back to defaults instead of crashing")
    func corruptDataIsSurvivable() {
        let backend = InMemorySettingsBackend()
        backend.saveData(Data("not json".utf8), forKey: "apps")
        backend.saveData(Data("not json".utf8), forKey: "callAudio")
        let store = SettingsStore(backend: backend)
        #expect(store.setting(for: music) == .unchanged)
        #expect(store.callAudio == .default)
    }
}
