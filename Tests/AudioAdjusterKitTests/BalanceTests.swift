import Testing
@testable import AudioAdjusterKit

private func isClose(_ lhs: Float, _ rhs: Float, tolerance: Float = 1e-4) -> Bool {
    abs(lhs - rhs) <= tolerance
}

@Suite("Balance")
struct BalanceTests {

    @Test("raising one app lowers the other, keeping the total")
    func twoAppsStayBalanced() {
        let result = Balance.apply(gains: ["a": 1.0, "b": 1.0], changed: "a", newGain: 1.5)
        #expect(isClose(result["a"]!, 1.5))
        #expect(isClose(result["b"]!, 0.5))
        #expect(isClose(Balance.total(result), 2.0))
    }

    @Test("the difference is shared equally across the others")
    func sharesEqually() {
        let result = Balance.apply(gains: ["a": 1.0, "b": 1.0, "c": 1.0], changed: "a", newGain: 1.6)
        #expect(isClose(result["a"]!, 1.6))
        #expect(isClose(result["b"]!, 0.7))
        #expect(isClose(result["c"]!, 0.7))
        #expect(isClose(Balance.total(result), 3.0))
    }

    @Test("lowering one app raises the others")
    func loweringRaisesOthers() {
        let result = Balance.apply(gains: ["a": 1.0, "b": 1.0], changed: "a", newGain: 0.4)
        #expect(isClose(result["a"]!, 0.4))
        #expect(isClose(result["b"]!, 1.6))
        #expect(isClose(Balance.total(result), 2.0))
    }

    @Test("a lone app is freely adjustable")
    func singleAppIsFree() {
        // The case that would be broken by forcing sliders to sum to 100%.
        let result = Balance.apply(gains: ["a": 1.0], changed: "a", newGain: 0.3)
        #expect(isClose(result["a"]!, 0.3))
        #expect(result.count == 1)
    }

    @Test("an app that hits silence stops absorbing and passes on the residual")
    func residualRedistributes() {
        // b can only give 0.2 before hitting zero; c must absorb the rest.
        let result = Balance.apply(gains: ["a": 1.0, "b": 0.2, "c": 1.0], changed: "a", newGain: 1.8)
        #expect(isClose(result["a"]!, 1.8))
        #expect(isClose(result["b"]!, 0.0))
        #expect(isClose(result["c"]!, 0.4))
        #expect(isClose(Balance.total(result), 2.2))
    }

    @Test("no app goes below silence or above the ceiling")
    func staysInRange() {
        let result = Balance.apply(gains: ["a": 1.0, "b": 0.1, "c": 0.1], changed: "a", newGain: GainStage.maxGain)
        for (_, gain) in result {
            #expect(gain >= 0)
            #expect(gain <= GainStage.maxGain)
        }
    }

    @Test("when the others are already silent the total simply rises")
    func totalCannotAlwaysHold() {
        // Nowhere left to take volume from; the drag still does what was asked.
        let result = Balance.apply(gains: ["a": 1.0, "b": 0.0], changed: "a", newGain: 2.0)
        #expect(isClose(result["a"]!, 2.0))
        #expect(isClose(result["b"]!, 0.0))
    }

    @Test("lowering is capped by the others' ceiling")
    func ceilingCapsRedistribution() {
        let result = Balance.apply(gains: ["a": 1.0, "b": GainStage.maxGain], changed: "a", newGain: 0.0)
        #expect(isClose(result["a"]!, 0.0))
        #expect(isClose(result["b"]!, GainStage.maxGain))
    }

    @Test("setting an app to the value it already has changes nothing")
    func noOpIsStable() {
        let gains: [String: Float] = ["a": 1.2, "b": 0.8, "c": 1.0]
        let result = Balance.apply(gains: gains, changed: "a", newGain: 1.2)
        for (key, value) in gains { #expect(isClose(result[key]!, value)) }
    }

    @Test("an out-of-range request is clamped before balancing")
    func clampsInput() {
        let result = Balance.apply(gains: ["a": 1.0, "b": 1.0], changed: "a", newGain: 99)
        #expect(result["a"]! == GainStage.maxGain)
        #expect(result["b"]! >= 0)
    }

    @Test("an unknown app is added without disturbing the rest unduly")
    func unknownAppIsHandled() {
        let result = Balance.apply(gains: ["a": 1.0], changed: "new", newGain: 0.5)
        #expect(isClose(result["new"]!, 0.5))
        #expect(result["a"] != nil)
    }

    @Test("repeated drags keep every value finite and in range")
    func staysStableUnderRepeatedDrags() {
        var gains: [String: Float] = ["a": 1.0, "b": 1.0, "c": 1.0, "d": 1.0]
        var seed: UInt64 = 99
        func random() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(seed >> 40) / Float(1 << 24)
        }
        let keys = Array(gains.keys)
        for _ in 0..<2000 {
            let key = keys[Int(random() * Float(keys.count)) % keys.count]
            gains = Balance.apply(gains: gains, changed: key, newGain: random() * GainStage.maxGain)
            for (_, value) in gains {
                #expect(value.isFinite)
                #expect(value >= 0)
                #expect(value <= GainStage.maxGain)
            }
        }
    }
}
