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

    @Test("anti-duck needs a channel on every other app, to compensate them")
    func antiDuckNeedsChannels() {
        let (store, _) = makeStore()
        #expect(store.requiresChannel(for: music) == false)
        store.isAntiDuckEnabled = true
        #expect(store.requiresChannel(for: music))
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

    @Test("anti-duck does not tap the call app, which is not ducked")
    func antiDuckSkipsCallApp() {
        let (store, _) = makeStore()
        store.isAntiDuckEnabled = true
        // The call is the thing causing the duck, not a victim of it.
        #expect(store.requiresChannel(for: "com.apple.avconferenced") == false)
        #expect(store.requiresChannel(for: music))
    }

    @Test("anti-duck leaves the user's own gain alone")
    func antiDuckLeavesGainAlone() {
        let (store, _) = makeStore()
        store.setGain(0.5, for: music)
        store.isAntiDuckEnabled = true
        // Compensation is applied by the channel, not folded into the user's number, so
        // the slider keeps meaning what it says.
        #expect(store.effectiveGain(for: music) == 0.5)
    }

    @Test("anti-duck never unmutes a muted app")
    func antiDuckRespectsMute() {
        let (store, _) = makeStore()
        store.setMuted(true, for: music)
        store.isAntiDuckEnabled = true
        #expect(store.effectiveGain(for: music) == 0)
    }

    @Test("anti-duck alone requires channels for otherwise untouched apps")
    func antiDuckRequiresChannels() {
        let (store, _) = makeStore()
        #expect(store.requiresChannel(for: music) == false)
        store.isAntiDuckEnabled = true
        #expect(store.requiresChannel(for: music))
    }

    @Test("gain stays within the supported range")
    func gainStaysClamped() {
        let (store, _) = makeStore()
        store.setGain(GainStage.maxGain, for: music)
        store.isAntiDuckEnabled = true
        #expect(store.effectiveGain(for: music) == GainStage.maxGain)
    }

    @Test("settings survive a restart")
    func persistence() {
        let backend = InMemorySettingsBackend()
        let first = SettingsStore(backend: backend)
        first.setGain(0.3, for: music)
        first.setMuted(true, for: music2)
        first.isAntiDuckEnabled = true
        first.preset = AntiDuckPreset(callEngineBundleIDs: ["x"])

        let reloaded = SettingsStore(backend: backend)
        #expect(reloaded.setting(for: music).gain == 0.3)
        #expect(reloaded.setting(for: music2).isMuted)
        #expect(reloaded.isAntiDuckEnabled)
        #expect(reloaded.preset.callEngineBundleIDs == ["x"])
    }

    @Test("corrupt stored data falls back to defaults instead of crashing")
    func corruptDataIsSurvivable() {
        let backend = InMemorySettingsBackend()
        backend.saveData(Data("not json".utf8), forKey: "apps")
        backend.saveData(Data("not json".utf8), forKey: "antiDuckPreset")
        let store = SettingsStore(backend: backend)
        #expect(store.setting(for: music) == .unchanged)
        #expect(store.preset == .default)
    }
}
