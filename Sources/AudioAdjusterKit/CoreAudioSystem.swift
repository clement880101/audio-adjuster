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
    ///
    /// `T` must be a trivial type — Core Audio writes raw bytes over the whole value, so
    /// anything holding an object reference would have ARC release a reference it never
    /// retained. Every property read through here is a C struct or integer. The bytes are
    /// handed over explicitly rather than as `&value`, which is the same thing but leaves
    /// the compiler unable to tell that `T` is trivial.
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
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size,
                                       UnsafeMutableRawPointer(pointer))
        }
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
    ///
    /// Core Audio writes a *retained* `CFStringRef` into the buffer and hands ownership to
    /// the caller. The pointer is therefore read as plain memory and adopted with
    /// `takeRetainedValue()`, which consumes that +1. Passing `&someCFString` instead lets
    /// Core Audio overwrite a reference ARC believes it already owns, and leaves the
    /// retain it handed over unbalanced.
    public static func string(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        operation: String
    ) throws -> String {
        var address = self.address(selector, scope: scope)
        var size = UInt32(MemoryLayout<UnsafeRawPointer?>.size)
        var raw: UnsafeRawPointer?
        let status = withUnsafeMutablePointer(to: &raw) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size,
                                       UnsafeMutableRawPointer(pointer))
        }
        guard status == noErr else { throw CoreAudioError(status: status, operation: operation) }
        guard let raw else { return "" }
        return Unmanaged<CFString>.fromOpaque(raw).takeRetainedValue() as String
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
    ]

    public init() {}

    public func displayName(pid: pid_t, bundleID: String) -> String? {
        if let friendly = RunningAppNameResolver.friendlyNames[bundleID] { return friendly }
        return NSRunningApplication(processIdentifier: pid)?.localizedName
    }
}
