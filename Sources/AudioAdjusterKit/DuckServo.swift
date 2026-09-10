import Foundation

/// Works out how much to boost other apps to cancel the system's call ducking.
///
/// Measured behaviour this is built on: during a call macOS applies a linear attenuation
/// of roughly 0.033 to every process that is not the call. A tap captures audio *before*
/// that attenuation, so re-rendering at 1/0.033 puts the audio back at its original level
/// once the system has ducked us in turn. The attenuation is linear well past full scale,
/// so the arithmetic holds for loud sources too.
///
/// The hazard this type exists to manage: if we are boosting 30x and the call ends, the
/// attenuation disappears and audio is instantly 30x too loud. Every rule below is
/// asymmetric in favour of being too quiet rather than too loud.
public struct DuckServo: Equatable {

    /// Hard ceiling on compensation, whatever a measurement claims. A wild reading must
    /// not be able to produce arbitrary gain.
    public static let maxCompensation: Float = 40

    /// Rendered levels below this are too close to the noise floor for the measured ratio
    /// to mean anything.
    public static let minimumUsableLevel: Float = 0.0005

    /// Fraction of the remaining distance travelled per update when increasing.
    /// Decreases are applied immediately and ignore this.
    public static let riseRate: Float = 0.4

    /// Current compensation multiplier. 1 means no compensation.
    public private(set) var compensation: Float = 1

    /// True once a usable measurement has been taken, so the UI can distinguish
    /// "calibrating" from "nothing to do".
    public private(set) var hasCalibrated = false

    public init() {}

    /// Feeds one observation of what we wrote versus what reached the device.
    ///
    /// - Parameters:
    ///   - renderedPeak: peak level we wrote into the output buffer.
    ///   - observedPeak: peak level actually measured on the output device.
    ///   - isCallActive: whether a call engine is currently producing audio.
    public mutating func update(renderedPeak: Float, observedPeak: Float, isCallActive: Bool) {
        // No call means no duck to cancel. Release at once rather than waiting for a
        // measurement to tell us: this is the path that protects against a 30x blast when
        // a call ends.
        guard isCallActive else {
            compensation = 1
            hasCalibrated = false
            return
        }

        // Too quiet to measure, or nonsense input. Hold the current value rather than
        // guessing; holding is safe because it is already a level we were sustaining.
        guard renderedPeak > DuckServo.minimumUsableLevel,
              observedPeak.isFinite, renderedPeak.isFinite, observedPeak > 0 else { return }

        let ratio = observedPeak / renderedPeak
        guard ratio > 0, ratio.isFinite else { return }

        let target = min(1 / ratio, DuckServo.maxCompensation)
        guard target.isFinite else { return }

        // Rise gradually, fall immediately. Being briefly too quiet is a cosmetic problem;
        // being briefly too loud is a physical one.
        if target < compensation {
            compensation = target
        } else {
            compensation += (target - compensation) * DuckServo.riseRate
        }
        compensation = min(max(compensation, 1), DuckServo.maxCompensation)
        hasCalibrated = true
    }

    /// Immediately abandons compensation. Used when anti-duck is switched off, the app is
    /// quitting, or anything unexpected happens.
    public mutating func release() {
        compensation = 1
        hasCalibrated = false
    }
}
