import CoreAudio
import Foundation

/// An application that Core Audio knows about, as shown in the menu bar list.
public struct AudioProcess: Identifiable, Equatable, Sendable {
    /// Every Core Audio process object this entry covers. An app can render audio from
    /// more than one process — a FaceTime call uses both FaceTime and avconferenced — and
    /// a single tap can cover them all, so they stay one control.
    public let objectIDs: [AudioObjectID]
    /// The process used for the icon and name.
    public let pid: pid_t
    public let bundleID: String
    public let name: String
    /// True when any covered process is currently sending audio to an output device.
    public let isPlaying: Bool

    /// Settings are keyed by bundle ID so they survive the app relaunching under a new PID.
    public var id: String { bundleID }

    public init(objectIDs: [AudioObjectID], pid: pid_t, bundleID: String, name: String, isPlaying: Bool) {
        self.objectIDs = objectIDs
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.isPlaying = isPlaying
    }
}

/// One process as Core Audio reports it, before naming and filtering.
public struct RawAudioProcess: Equatable, Sendable {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?
    public let isRunning: Bool
    public let isRunningOutput: Bool

    public init(objectID: AudioObjectID, pid: pid_t, bundleID: String?, isRunning: Bool, isRunningOutput: Bool) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.isRunning = isRunning
        self.isRunningOutput = isRunningOutput
    }
}

/// Seam over Core Audio's process enumeration, so list assembly can be tested with a fake.
public protocol AudioProcessSource: AnyObject {
    func rawProcesses() -> [RawAudioProcess]
}

/// Seam over `NSRunningApplication`, for the same reason.
public protocol AppNameResolver: AnyObject {
    func displayName(pid: pid_t, bundleID: String) -> String?
}
