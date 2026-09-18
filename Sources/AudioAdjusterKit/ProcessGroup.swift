import Foundation

/// Collapses the several processes an app may use for audio into the one thing the user
/// recognises.
///
/// FaceTime is the case that forces this: a call shows up as both `com.apple.FaceTime` and
/// `com.apple.avconferenced`, which is two bars for one conversation. A tap can cover
/// several process objects at once, so a group stays a single control.
public enum ProcessGroup {

    /// Processes that belong to another app's entry.
    private static let canonicalIDs: [String: String] = [
        "com.apple.avconferenced": "com.apple.FaceTime",
    ]

    /// Names for groups whose own app process may not appear in the list — during a call
    /// `avconferenced` can be producing audio while FaceTime itself is silent.
    private static let groupNames: [String: String] = [
        "com.apple.FaceTime": "FaceTime",
        "com.apple.TelephonyUtilities": "Phone call audio",
    ]

    /// The identity a process's settings and volume bar belong to.
    public static func canonicalID(for bundleID: String) -> String {
        canonicalIDs[bundleID] ?? bundleID
    }

    /// A name for a group, when no member process can supply one.
    public static func name(forGroup canonicalID: String) -> String? {
        groupNames[canonicalID]
    }

    /// True when this bundle ID is a helper rather than the app itself.
    public static func isMember(_ bundleID: String) -> Bool {
        canonicalIDs[bundleID] != nil
    }
}
