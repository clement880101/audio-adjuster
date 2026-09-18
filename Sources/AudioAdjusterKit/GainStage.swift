import Foundation

/// Applies a per-app volume gain to raw audio samples.
///
/// This is the only code in the project that runs on the Core Audio IO thread, so it is
/// allocation-free, lock-free, and calls nothing that could block. It is a plain struct
/// with no reference counting on the hot path.
///
/// Gain changes are ramped across the buffer rather than applied as a step, because a
/// discontinuity in gain is audible as a click ("zipper noise") when a slider moves.
///
/// Usage per IO cycle:
/// ```
/// let inc = stage.increment(toward: target, frameCount: frames)
/// for channel in channels { stage.apply(to: channel, frameCount: frames, increment: inc) }
/// stage.commit(toward: target)
/// ```
/// `apply` does not mutate the stage, so every channel of one cycle ramps identically.
public struct GainStage {

    /// Ceiling on gain.
    ///
    /// Useful headroom rather than a promise: audio already near full scale cannot be made
    /// louder, and pushing it only drives the limiter. Most app audio sits well below full
    /// scale, which is where this range earns its keep — a source peaking at 0.05 has
    /// twenty times of genuine headroom, one peaking at 0.9 has almost none.
    public static let maxGain: Float = 10.0

    /// Level above which soft clipping begins. Below it, output is bit-identical to input.
    static let clipThreshold: Float = 0.9

    /// The gain currently in effect, i.e. where the next ramp starts.
    public private(set) var current: Float

    public init(current: Float = 1.0) {
        self.current = GainStage.clampGain(current)
    }

    /// Clamps a requested gain into the supported range.
    public static func clampGain(_ gain: Float) -> Float {
        if gain.isNaN { return 1.0 }
        return min(max(gain, 0), maxGain)
    }

    /// Per-sample step that moves `current` to `target` over exactly `frameCount` frames.
    public func increment(toward target: Float, frameCount: Int) -> Float {
        guard frameCount > 0 else { return 0 }
        return (GainStage.clampGain(target) - current) / Float(frameCount)
    }

    /// Applies the ramped gain to one channel's samples in place.
    ///
    /// Deliberately non-mutating: an IO cycle hands us several channels that must all
    /// ramp from the same starting gain.
    public func apply(to samples: UnsafeMutablePointer<Float>, frameCount: Int, increment: Float) {
        var gain = current
        for index in 0..<frameCount {
            samples[index] = GainStage.softClip(samples[index] * gain)
            gain += increment
        }
    }

    /// Commits the ramp. Call once per IO cycle, after every channel has been processed.
    public mutating func commit(toward target: Float) {
        current = GainStage.clampGain(target)
    }

    /// Saturating limiter with a soft knee.
    ///
    /// Boosting past unity can push samples outside [-1, 1], which clips harshly or wraps
    /// depending on the downstream format. A `tanh`-style clipper would avoid that but
    /// would also alter audio at unity gain, so this one is exactly linear below the
    /// threshold and only then curves asymptotically toward ±1. It is continuous and has
    /// slope 1 at the knee, so the transition is inaudible.
    public static func softClip(_ sample: Float) -> Float {
        let magnitude = abs(sample)
        if magnitude <= clipThreshold { return sample }
        let sign: Float = sample < 0 ? -1 : 1
        let over = magnitude - clipThreshold
        let range = 1 - clipThreshold
        return sign * (clipThreshold + range * (over / (over + range)))
    }
}
