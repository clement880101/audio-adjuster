import Testing
@testable import AudioAdjusterKit

/// A duck of 0.033 is what was measured on a live FaceTime call.
private let measuredDuckRatio: Float = 0.033

private func settle(_ servo: inout DuckServo, ratio: Float, rendered: Float = 0.5, steps: Int = 40) {
    for _ in 0..<steps {
        servo.update(renderedPeak: rendered, observedPeak: rendered * ratio, isCallActive: true)
    }
}

@Suite("DuckServo")
struct DuckServoTests {

    @Test("starts at no compensation")
    func startsNeutral() {
        let servo = DuckServo()
        #expect(servo.compensation == 1)
        #expect(servo.hasCalibrated == false)
    }

    @Test("converges on the inverse of the measured duck")
    func convergesOnInverse() {
        var servo = DuckServo()
        settle(&servo, ratio: measuredDuckRatio)
        #expect(abs(servo.compensation - 1 / measuredDuckRatio) < 0.5)
        #expect(servo.hasCalibrated)
    }

    @Test("no call releases compensation immediately")
    func releasesWhenCallEnds() {
        var servo = DuckServo()
        settle(&servo, ratio: measuredDuckRatio)
        #expect(servo.compensation > 20)
        // The dangerous transition: one observation must be enough.
        servo.update(renderedPeak: 0.5, observedPeak: 0.5, isCallActive: false)
        #expect(servo.compensation == 1)
    }

    @Test("a duck that disappears mid-call drops compensation in one step")
    func fallsImmediately() {
        var servo = DuckServo()
        settle(&servo, ratio: measuredDuckRatio)
        // Ratio back to 1: no attenuation any more.
        servo.update(renderedPeak: 0.5, observedPeak: 0.5, isCallActive: true)
        #expect(servo.compensation == 1)
    }

    @Test("compensation never exceeds the ceiling")
    func respectsCeiling() {
        var servo = DuckServo()
        // An absurdly deep duck must not produce unbounded gain.
        settle(&servo, ratio: 0.00001, steps: 200)
        #expect(servo.compensation <= DuckServo.maxCompensation)
    }

    @Test("compensation never goes below unity")
    func neverAttenuates() {
        var servo = DuckServo()
        // Observed louder than rendered would imply compensation < 1.
        settle(&servo, ratio: 4.0)
        #expect(servo.compensation >= 1)
    }

    @Test("rise is gradual so a single reading cannot jump to full gain")
    func riseIsGradual() {
        var servo = DuckServo()
        servo.update(renderedPeak: 0.5, observedPeak: 0.5 * measuredDuckRatio, isCallActive: true)
        #expect(servo.compensation < 1 / measuredDuckRatio)
        #expect(servo.compensation > 1)
    }

    @Test("levels too close to the noise floor are ignored")
    func ignoresQuietMeasurements() {
        var servo = DuckServo()
        settle(&servo, ratio: measuredDuckRatio)
        let held = servo.compensation
        servo.update(renderedPeak: DuckServo.minimumUsableLevel / 2, observedPeak: 0, isCallActive: true)
        #expect(servo.compensation == held)
    }

    @Test("silence on the device does not divide by zero")
    func handlesZeroObservation() {
        var servo = DuckServo()
        settle(&servo, ratio: measuredDuckRatio)
        let held = servo.compensation
        servo.update(renderedPeak: 0.5, observedPeak: 0, isCallActive: true)
        #expect(servo.compensation == held)
    }

    @Test("non-finite measurements are ignored")
    func handlesNonFinite() {
        var servo = DuckServo()
        settle(&servo, ratio: measuredDuckRatio)
        let held = servo.compensation
        servo.update(renderedPeak: .nan, observedPeak: 0.1, isCallActive: true)
        servo.update(renderedPeak: 0.5, observedPeak: .infinity, isCallActive: true)
        #expect(servo.compensation == held)
        #expect(servo.compensation.isFinite)
    }

    @Test("release abandons compensation")
    func releaseWorks() {
        var servo = DuckServo()
        settle(&servo, ratio: measuredDuckRatio)
        servo.release()
        #expect(servo.compensation == 1)
        #expect(servo.hasCalibrated == false)
    }

    @Test("compensation stays finite and bounded under random input")
    func staysBounded() {
        var servo = DuckServo()
        var seed: UInt64 = 12345
        func random() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(seed >> 40) / Float(1 << 24)
        }
        for _ in 0..<5000 {
            servo.update(renderedPeak: random() * 4, observedPeak: random() * 4, isCallActive: random() > 0.2)
            #expect(servo.compensation.isFinite)
            #expect(servo.compensation >= 1)
            #expect(servo.compensation <= DuckServo.maxCompensation)
        }
    }
}
