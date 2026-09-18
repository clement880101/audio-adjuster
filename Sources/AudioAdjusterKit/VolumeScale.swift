import Foundation

/// Maps a position along a volume bar to a gain.
///
/// Two different curves, meeting at 100% in the middle of the bar.
///
/// **Below unity, linear.** Cutting volume is proportional and has to reach exact silence,
/// which a logarithmic curve never does.
///
/// **Above unity, logarithmic.** With a range running to 1000%, a linear boost half would
/// give 100–200% — the range anyone actually reaches for — about five percent of the bar,
/// while the top half wandered through gains nothing will survive. Logarithmic spacing
/// makes each equal drag a roughly equal multiplication instead: the midpoint of the boost
/// half is √10 ≈ 316%, not 550%.
public enum VolumeScale {

    /// Fraction of the bar's width at which gain is exactly 100%.
    public static let unityPosition: Float = 0.5

    /// Gain for a position along the bar, where 0 is the left edge and 1 the right.
    public static func gain(atPosition position: Float) -> Float {
        let clamped = min(max(position, 0), 1)
        if clamped <= unityPosition {
            return clamped / unityPosition
        }
        let above = (clamped - unityPosition) / (1 - unityPosition)
        return pow(GainStage.maxGain, above)
    }

    /// Where a gain sits along the bar. Inverse of `gain(atPosition:)`.
    public static func position(forGain gain: Float) -> Float {
        let clamped = GainStage.clampGain(gain)
        if clamped <= 1 {
            return clamped * unityPosition
        }
        let above = log(clamped) / log(GainStage.maxGain)
        return unityPosition + above * (1 - unityPosition)
    }
}
