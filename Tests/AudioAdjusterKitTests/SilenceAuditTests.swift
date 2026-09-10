import Testing
@testable import AudioAdjusterKit

@Suite("SilenceAudit")
struct SilenceAuditTests {

    @Test("audio flowing is never reported as a failure")
    func audibleChannelIsFine() {
        var audit = SilenceAudit()
        var frames: UInt64 = 0
        for _ in 0..<10 {
            frames += 1000
            #expect(audit.record(frames: frames, peak: 0.02, isPlaying: true) == false)
        }
    }

    @Test("a playing app rendering only silence is reported after the threshold")
    func silentTapIsCaught() {
        var audit = SilenceAudit()
        var frames: UInt64 = 0
        var results: [Bool] = []
        for _ in 0..<SilenceAudit.failureThreshold {
            frames += 1000
            results.append(audit.record(frames: frames, peak: 0, isPlaying: true))
        }
        #expect(results.dropLast().allSatisfy { $0 == false })
        #expect(results.last == true)
    }

    @Test("an app that is not playing is never reported")
    func silentAppIsNotAFailure() {
        var audit = SilenceAudit()
        var frames: UInt64 = 0
        for _ in 0..<20 {
            frames += 1000
            #expect(audit.record(frames: frames, peak: 0, isPlaying: false) == false)
        }
    }

    @Test("a stalled IO proc is not mistaken for a silent tap")
    func noNewFramesCarriesNoInformation() {
        var audit = SilenceAudit()
        for _ in 0..<20 {
            #expect(audit.record(frames: 1000, peak: 0, isPlaying: true) == false)
        }
    }

    @Test("one audible observation clears the count")
    func recoveryResets() {
        var audit = SilenceAudit()
        var frames: UInt64 = 0
        for _ in 0..<(SilenceAudit.failureThreshold - 1) {
            frames += 1000
            _ = audit.record(frames: frames, peak: 0, isPlaying: true)
        }
        frames += 1000
        #expect(audit.record(frames: frames, peak: 0.5, isPlaying: true) == false)
        frames += 1000
        // Having heard audio, a single silent sample must not trip the threshold.
        #expect(audit.record(frames: frames, peak: 0, isPlaying: true) == false)
    }

    @Test("a gap in playback clears the count")
    func pauseResets() {
        var audit = SilenceAudit()
        var frames: UInt64 = 0
        for _ in 0..<(SilenceAudit.failureThreshold - 1) {
            frames += 1000
            _ = audit.record(frames: frames, peak: 0, isPlaying: true)
        }
        frames += 1000
        _ = audit.record(frames: frames, peak: 0, isPlaying: false)
        frames += 1000
        #expect(audit.record(frames: frames, peak: 0, isPlaying: true) == false)
    }
}
