import Foundation

/// File-based diagnostic log.
///
/// The app is ad-hoc signed and its `os_log` output does not reach the system log store,
/// so this writes somewhere readable instead. Enabled by setting AUDIOADJUSTER_DEBUG=1 or
/// creating the log file; off by default so it costs nothing in normal use.
enum DebugLog {

    static let path = NSString(string: "~/Library/Logs/AudioAdjuster-debug.log").expandingTildeInPath

    private static let queue = DispatchQueue(label: "com.audioadjuster.debuglog")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static let isEnabled: Bool = {
        if ProcessInfo.processInfo.environment["AUDIOADJUSTER_DEBUG"] == "1" { return true }
        return FileManager.default.fileExists(atPath: path)
    }()

    static func write(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let line = "\(formatter.string(from: Date())) \(message())\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}
