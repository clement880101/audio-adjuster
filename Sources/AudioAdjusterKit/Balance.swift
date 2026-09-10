import Foundation

/// Linked volume sliders: raising one app lowers the others by the same total amount, so
/// the mix keeps a constant sum.
///
/// Gains stay absolute — 100% means "as macOS would play it" — so opening a fourth app
/// does not make the first three quieter. Only a deliberate drag moves anything.
public enum Balance {

    /// Applies a new gain to one app and pushes the difference onto the others.
    ///
    /// The difference is shared equally rather than proportionally: equal shares are
    /// predictable when dragging, and an app already at silence is not treated as owing
    /// more than the rest. An app that hits 0 or the ceiling stops absorbing, and its
    /// residual is redistributed to apps that still have room.
    ///
    /// When there are no other apps there is nothing to balance against, so the dragged
    /// app simply takes the value — a single app stays freely adjustable.
    ///
    /// The sum cannot always be preserved: if every other app is already at silence there
    /// is nowhere left to take volume from. In that case the dragged app still gets what
    /// was asked for and the total rises.
    public static func apply(
        gains: [String: Float],
        changed: String,
        newGain: Float
    ) -> [String: Float] {
        var result = gains
        let clampedNew = GainStage.clampGain(newGain)
        let previous = gains[changed] ?? 1.0
        result[changed] = clampedNew

        var others = Set(gains.keys)
        others.remove(changed)
        guard !others.isEmpty else { return result }

        // What the others must give up between them, negative when the dragged app rose.
        var remaining = -(clampedNew - previous)
        var eligible = others

        // Bounded loop: each pass either settles the residual or removes at least one app
        // from the eligible set.
        var passes = 0
        while abs(remaining) > 1e-6, !eligible.isEmpty, passes < 8 {
            passes += 1
            let share = remaining / Float(eligible.count)
            var residual: Float = 0
            var stillEligible = Set<String>()

            for bundleID in eligible {
                let requested = (result[bundleID] ?? 1.0) + share
                let clamped = GainStage.clampGain(requested)
                residual += requested - clamped
                result[bundleID] = clamped
                // An app sitting at a limit cannot absorb any more in that direction.
                if clamped > 0, clamped < GainStage.maxGain { stillEligible.insert(bundleID) }
            }

            remaining = residual
            eligible = stillEligible
        }

        return result
    }

    /// Total of all gains, which balancing aims to hold constant.
    public static func total(_ gains: [String: Float]) -> Float {
        gains.values.reduce(0, +)
    }
}
