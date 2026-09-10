import CoreAudio
import Foundation

/// An application that Core Audio knows about, as shown in the menu bar list.
public struct AudioProcess: Identifiable, Equatable, Sendable {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String
    public let name: String
    /// True when the app is currently sending audio to an output device.
    public let isPlaying: Bool

    /// Settings are keyed by bundle ID so they survive the app relaunching under a new PID.
    public var id: String { bundleID }

    public init(objectID: AudioObjectID, pid: pid_t, bundleID: String, name: String, isPlaying: Bool) {
        self.objectID = objectID
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

/// What the running-application list knows about a process.
public struct ResolvedApp: Equatable, Sendable {
    public let name: String
    /// True for an ordinary app with a Dock icon. Menu bar agents and background daemons
    /// are false, which is what separates Firefox from `loginwindow`.
    public let isRegularApp: Bool

    public init(name: String, isRegularApp: Bool) {
        self.name = name
        self.isRegularApp = isRegularApp
    }
}

/// Seam over `NSRunningApplication`, for the same reason.
public protocol AppNameResolver: AnyObject {
    func resolve(pid: pid_t, bundleID: String) -> ResolvedApp?
}
