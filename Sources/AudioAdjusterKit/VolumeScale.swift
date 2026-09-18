import Foundation

/// Maps a position along a volume bar to a gain.
///
/// The mapping is deliberately not linear. With a range running to 400%, a linear bar
/// would squeeze everyday adjustment — anything below normal volume — into the first
/// quarter, where a pixel is worth several percent. Putting 100% at the midpoint gives
/// half the bar to the range people actually use and half to headroom.
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
        return 1 + above * (GainStage.maxGain - 1)
    }

    /// Where a gain sits along the bar. Inverse of `gain(atPosition:)`.
    public static func position(forGain gain: Float) -> Float {
        let clamped = GainStage.clampGain(gain)
        if clamped <= 1 {
            return clamped * unityPosition
        }
        let above = (clamped - 1) / (GainStage.maxGain - 1)
        return unityPosition + above * (1 - unityPosition)
    }
}
