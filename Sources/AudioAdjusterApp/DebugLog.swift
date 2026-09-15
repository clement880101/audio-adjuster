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

    /// Beyond this the log is truncated. It is a diagnostic, not an archive, and it
    /// previously reached 6MB by writing a line every second.
    private static let sizeLimit = 512 * 1024

    private static var lastMessage = ""

    static func write(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = message()
        // The view rebuilds once a second whether or not anything changed; logging every
        // one of those buried the events that matter and grew the file without bound.
        guard text != lastMessage else { return }
        lastMessage = text

        let line = "\(formatter.string(from: Date())) \(text)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            let url = URL(fileURLWithPath: path)
            if let handle = FileHandle(forWritingAtPath: path) {
                if handle.seekToEndOfFile() > UInt64(sizeLimit) {
                    try? handle.truncate(atOffset: 0)
                }
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
