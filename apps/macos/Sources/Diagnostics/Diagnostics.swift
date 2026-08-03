import Foundation

/// Diagnostics/logging utilities.
///
/// AGENTS.md hard rule 4: log metadata only (event types, counts, directions)
/// — never keystrokes, clipboard contents, or input payloads.
///
/// Writes timestamped lines to a plain-text log file so on-device/e2e
/// debugging does not depend on the unified log being queryable for
/// non-sandboxed menu bar binaries.
public enum Diagnostics {
    private static let lock = NSLock()
    private static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Ampersand")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("diag.log")
    }()

    public static func log(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "\(Self.timestamp()) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.data(using: .utf8)?.write(to: logURL)
        }
    }

    public static var logPath: String { logURL.path }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
