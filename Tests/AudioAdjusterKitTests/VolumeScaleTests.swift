import Testing
@testable import AudioAdjusterKit

private func isClose(_ lhs: Float, _ rhs: Float, tolerance: Float = 1e-5) -> Bool {
    abs(lhs - rhs) <= tolerance
}

@Suite("VolumeScale")
struct VolumeScaleTests {

    @Test("the ends of the bar are silence and maximum")
    func endpoints() {
        #expect(VolumeScale.gain(atPosition: 0) == 0)
        #expect(isClose(VolumeScale.gain(atPosition: 1), GainStage.maxGain))
    }

    @Test("normal volume sits at the midpoint")
    func unityAtMidpoint() {
        // Half the bar for the range people actually use, half for headroom.
        #expect(isClose(VolumeScale.gain(atPosition: VolumeScale.unityPosition), 1.0))
        #expect(isClose(VolumeScale.position(forGain: 1.0), VolumeScale.unityPosition))
    }

    @Test("the lower half is linear in gain")
    func lowerHalfIsLinear() {
        #expect(isClose(VolumeScale.gain(atPosition: 0.25), 0.5))
        #expect(isClose(VolumeScale.gain(atPosition: 0.1), 0.2))
    }

    @Test("the upper half is logarithmic, so equal drags multiply equally")
    func upperHalfIsLogarithmic() {
        // The midpoint of the boost half is the geometric mean, not the arithmetic one:
        // for a 10x range that is sqrt(10) — about 316%, not 550%.
        let middle = VolumeScale.gain(atPosition: 0.75)
        #expect(isClose(middle, GainStage.maxGain.squareRoot(), tolerance: 1e-3))
        #expect(middle > 1)
        #expect(middle < GainStage.maxGain)
    }

    @Test("equal steps above unity multiply by a constant factor")
    func equalStepsMultiply() {
        // What makes a long boost range usable: the same drag is worth the same
        // proportional change wherever you do it.
        let a = VolumeScale.gain(atPosition: 0.60)
        let b = VolumeScale.gain(atPosition: 0.70)
        let c = VolumeScale.gain(atPosition: 0.80)
        #expect(isClose(b / a, c / b, tolerance: 1e-3))
    }

    @Test("the everyday boost range gets a usable share of the bar")
    func boostRangeIsReachable() {
        // A linear bar would give 100-200% about 5% of the width at this range.
        let span = VolumeScale.position(forGain: 2) - VolumeScale.position(forGain: 1)
        #expect(span > 0.12)
    }

    @Test("position and gain are inverses of each other")
    func roundTrips() {
        for step in 0...100 {
            let position = Float(step) / 100
            let roundTripped = VolumeScale.position(forGain: VolumeScale.gain(atPosition: position))
            #expect(isClose(roundTripped, position, tolerance: 1e-4))
        }
    }

    @Test("gain round trips through position too")
    func gainRoundTrips() {
        for step in 0...100 {
            let gain = Float(step) / 100 * GainStage.maxGain
            let roundTripped = VolumeScale.gain(atPosition: VolumeScale.position(forGain: gain))
            #expect(isClose(roundTripped, gain, tolerance: 1e-4))
        }
    }

    @Test("positions outside the bar are clamped")
    func clampsPosition() {
        #expect(VolumeScale.gain(atPosition: -5) == 0)
        #expect(isClose(VolumeScale.gain(atPosition: 5), GainStage.maxGain))
        #expect(VolumeScale.position(forGain: -1) == 0)
        #expect(isClose(VolumeScale.position(forGain: 99), 1))
    }

    @Test("the mapping never decreases")
    func isMonotonic() {
        var previous: Float = -1
        for step in 0...1000 {
            let gain = VolumeScale.gain(atPosition: Float(step) / 1000)
            #expect(gain >= previous)
            previous = gain
        }
    }
}
