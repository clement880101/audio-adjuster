import AppKit
import CoreAudio
import Foundation

public struct CoreAudioError: Error, CustomStringConvertible {
    public let status: OSStatus
    public let operation: String

    public init(status: OSStatus, operation: String) {
        self.status = status
        self.operation = operation
    }
    public var description: String { "\(operation) failed with OSStatus \(status)" }
}

/// Thin, typed wrapper over the `AudioObjectGetPropertyData` boilerplate.
public enum CoreAudioProperty {

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// Reads a fixed-size property value.
    public static func value<T>(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        default fallback: T,
        operation: String
    ) throws -> T {
        var address = self.address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        var value = fallback
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr else { throw CoreAudioError(status: status, operation: operation) }
        return value
    }

    /// Reads a variable-length array property.
    public static func array<T>(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        of type: T.Type,
        operation: String
    ) throws -> [T] {
        var address = self.address(selector, scope: scope)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
        guard status == noErr else { throw CoreAudioError(status: status, operation: operation) }
        let count = Int(size) / MemoryLayout<T>.size
        guard count > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, raw)
        guard status == noErr else { throw CoreAudioError(status: status, operation: operation) }
        return Array(UnsafeBufferPointer(start: raw.bindMemory(to: T.self, capacity: count), count: count))
    }

    /// Reads a `CFString` property.
    public static func string(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        operation: String
    ) throws -> String {
        var address = self.address(selector, scope: scope)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString = "" as CFString
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr else { throw CoreAudioError(status: status, operation: operation) }
        return value as String
    }
}

/// Live Core Audio implementation of the process enumeration seam.
public final class CoreAudioSystem: AudioProcessSource {

    public init() {}

    public func rawProcesses() -> [RawAudioProcess] {
        let objectIDs = (try? CoreAudioProperty.array(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyProcessObjectList,
            of: AudioObjectID.self,
            operation: "read process object list"
        )) ?? []

        return objectIDs.compactMap { objectID in
            // A process can vanish between enumeration and inspection, so a failed read
            // here is expected rather than exceptional.
            guard let pid: pid_t = try? CoreAudioProperty.value(
                objectID, kAudioProcessPropertyPID, default: -1, operation: "read pid"
            ), pid > 0 else { return nil }

            let bundleID = try? CoreAudioProperty.string(
                objectID, kAudioProcessPropertyBundleID, operation: "read bundle id"
            )
            let isRunning: UInt32 = (try? CoreAudioProperty.value(
                objectID, kAudioProcessPropertyIsRunning, default: 0, operation: "read isRunning"
            )) ?? 0
            let isRunningOutput: UInt32 = (try? CoreAudioProperty.value(
                objectID, kAudioProcessPropertyIsRunningOutput, default: 0, operation: "read isRunningOutput"
            )) ?? 0

            return RawAudioProcess(
                objectID: objectID,
                pid: pid,
                bundleID: bundleID,
                isRunning: isRunning != 0,
                isRunningOutput: isRunningOutput != 0
            )
        }
    }

    /// The device the system is currently playing through.
    public static func defaultOutputDeviceID() throws -> AudioDeviceID {
        try CoreAudioProperty.value(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDefaultOutputDevice,
            default: AudioDeviceID(kAudioObjectUnknown),
            operation: "read default output device"
        )
    }

    public static func deviceUID(_ deviceID: AudioDeviceID) throws -> String {
        try CoreAudioProperty.string(deviceID, kAudioDevicePropertyDeviceUID, operation: "read device UID")
    }
}

/// Resolves display names from the running-application list.
public final class RunningAppNameResolver: AppNameResolver {

    /// Processes that carry audio on another app's behalf, named as the user thinks of
    /// them rather than as the process is called.
    private static let friendlyNames = [
        "com.apple.avconferenced": "FaceTime call audio",
        "com.apple.TelephonyUtilities": "Phone call audio",
        // Plays the chime when a power adapter is connected.
        "com.apple.PowerChime": "Power adapter chime",
        // Renders AudioServicesPlaySystemSound for every app, so alert and notification
        // sounds arrive here rather than attributed to whichever app asked for them.
        "systemsoundserverd": "System alerts & UI sounds",
    ]

    public init() {}

    public func displayName(pid: pid_t, bundleID: String) -> String? {
        if let friendly = RunningAppNameResolver.friendlyNames[bundleID] { return friendly }
        return NSRunningApplication(processIdentifier: pid)?.localizedName
    }
}
