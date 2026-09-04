import Testing
@testable import AudioAdjusterKit

private func isClose(_ lhs: Float, _ rhs: Float, tolerance: Float = 1e-6) -> Bool {
    abs(lhs - rhs) <= tolerance
}

/// Runs one full IO cycle over `samples` and returns the processed buffer.
private func process(_ samples: [Float], from start: Float, to target: Float) -> [Float] {
    var stage = GainStage(current: start)
    var buffer = samples
    let increment = stage.increment(toward: target, frameCount: buffer.count)
    buffer.withUnsafeMutableBufferPointer { pointer in
        stage.apply(to: pointer.baseAddress!, frameCount: pointer.count, increment: increment)
    }
    stage.commit(toward: target)
    return buffer
}

@Suite("GainStage")
struct GainStageTests {

    @Test("unity gain leaves samples untouched")
    func unityGainIsTransparent() {
        let input: [Float] = [0, 0.25, -0.5, 0.75, -0.9, 0.1]
        #expect(process(input, from: 1.0, to: 1.0) == input)
    }

    @Test("zero gain silences")
    func zeroGainSilences() {
        #expect(process([0.5, -0.5, 0.9], from: 0, to: 0) == [0, 0, 0])
    }

    @Test("steady half gain halves every sample")
    func halfGainHalves() {
        let output = process([0.4, -0.8, 0.2], from: 0.5, to: 0.5)
        #expect(isClose(output[0], 0.2))
        #expect(isClose(output[1], -0.4))
        #expect(isClose(output[2], 0.1))
    }

    @Test("ramp starts at the current gain and steps evenly toward the target")
    func rampShape() {
        // A constant input makes the ramp shape directly observable in the output.
        var stage = GainStage(current: 0)
        var buffer = [Float](repeating: 1.0, count: 4)
        let increment = stage.increment(toward: 1.0, frameCount: 4)
        buffer.withUnsafeMutableBufferPointer {
            stage.apply(to: $0.baseAddress!, frameCount: 4, increment: increment)
        }
        #expect(isClose(buffer[0], 0.0))
        #expect(isClose(buffer[1], 0.25))
        #expect(isClose(buffer[2], 0.5))
        #expect(isClose(buffer[3], 0.75))

        stage.commit(toward: 1.0)
        #expect(isClose(stage.current, 1.0))
    }

    @Test("every channel of one cycle ramps identically")
    func channelsRampTogether() {
        let stage = GainStage(current: 0.2)
        var left = [Float](repeating: 1, count: 4)
        var right = [Float](repeating: 1, count: 4)
        let increment = stage.increment(toward: 1.0, frameCount: 4)
        left.withUnsafeMutableBufferPointer { stage.apply(to: $0.baseAddress!, frameCount: 4, increment: increment) }
        right.withUnsafeMutableBufferPointer { stage.apply(to: $0.baseAddress!, frameCount: 4, increment: increment) }
        #expect(left == right)
    }

    @Test("gain is clamped into the supported range")
    func gainClamping() {
        #expect(GainStage.clampGain(-3) == 0)
        #expect(GainStage.clampGain(99) == GainStage.maxGain)
        #expect(GainStage.clampGain(0.5) == 0.5)
        // A NaN gain would otherwise turn the whole buffer into NaN.
        #expect(GainStage.clampGain(.nan) == 1.0)
    }

    @Test("soft clip is transparent below the knee")
    func softClipTransparent() {
        for sample in stride(from: Float(-0.9), through: 0.9, by: 0.1) {
            #expect(isClose(GainStage.softClip(sample), sample))
        }
    }

    @Test("soft clip never exceeds full scale")
    func softClipBounded() {
        for sample in stride(from: Float(-8), through: 8, by: 0.05) {
            #expect(abs(GainStage.softClip(sample)) <= 1.0)
        }
    }

    @Test("soft clip is monotonic and continuous at the knee")
    func softClipSmooth() {
        var previous = GainStage.softClip(-8)
        for sample in stride(from: Float(-8), through: 8, by: 0.01) {
            let value = GainStage.softClip(sample)
            #expect(value >= previous - 1e-6)
            previous = value
        }
        let knee = GainStage.clipThreshold
        #expect(isClose(GainStage.softClip(knee), knee))
        #expect(isClose(GainStage.softClip(knee + 1e-4), knee + 1e-4, tolerance: 1e-3))
    }

    @Test("boost above unity is limited rather than wrapped")
    func boostIsLimited() {
        let output = process([0.8, -0.8], from: 2.0, to: 2.0)
        #expect(output[0] > 0.9)
        #expect(output[0] <= 1.0)
        #expect(output[1] >= -1.0)
    }

    @Test("an empty buffer produces no increment")
    func emptyBuffer() {
        #expect(GainStage(current: 0.5).increment(toward: 1.0, frameCount: 0) == 0)
    }
}
