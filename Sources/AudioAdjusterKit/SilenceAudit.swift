import Foundation

/// Watches one channel for the failure mode where a tap is created successfully but
/// delivers digital silence.
///
/// This happens when the process lacks the `kTCCServiceAudioCapture` grant. Core Audio
/// reports no error: the tap exists, the format and channel counts are right, and the IO
/// proc runs — the buffers are simply full of zeros. Since the tap also mutes the app's
/// own output, the result is an app that has gone silent with nothing rendered in its
/// place, which is the worst outcome this project can produce.
///
/// Detecting it needs a few consecutive observations, because an app that is genuinely
/// silent for a moment looks identical in a single sample.
public struct SilenceAudit: Equatable {

    /// Consecutive silent observations before a channel is declared broken. At the app's
    /// two-second refresh this is roughly six seconds of confirmed silence.
    public static let failureThreshold = 3

    private var consecutiveSilentChecks = 0
    private var lastFrames: UInt64 = 0

    public init() {}

    /// Records one observation. Returns true when the channel should be released.
    ///
    /// - Parameters:
    ///   - frames: total frames rendered so far by this channel.
    ///   - peak: loudest sample seen since the previous observation.
    ///   - isPlaying: whether the source app is currently sending audio to a device.
    public mutating func record(frames: UInt64, peak: Float, isPlaying: Bool) -> Bool {
        // An app that is not playing is expected to be silent; that says nothing.
        guard isPlaying else {
            consecutiveSilentChecks = 0
            lastFrames = frames
            return false
        }
        // No new frames means the IO proc has not run since the last check, so this
        // observation carries no information either.
        guard frames > lastFrames else {
            lastFrames = frames
            return false
        }
        lastFrames = frames

        if peak > 0 {
            consecutiveSilentChecks = 0
            return false
        }
        consecutiveSilentChecks += 1
        return consecutiveSilentChecks >= SilenceAudit.failureThreshold
    }
}
