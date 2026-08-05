import Foundation

/// Diagnostics/logging utilities.
///
/// AGENTS.md hard rule 4: log metadata only (event types, counts, directions)
/// — never keystrokes, clipboard contents, or input payloads.
///
/// Writes timestamped lines to a plain-text log file so on-device/e2e
/// debugging does not depend on the unified log being queryable for
/// non-sandboxed menu bar binaries.
///
/// Logging happens on the event-tap thread, so file I/O is batched: lines are
/// buffered in memory and flushed either when the buffer fills or on a 1 s
/// timer. `log(_:)` itself never touches the file, keeping per-event cost to
/// a lock + append.
public enum Diagnostics {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var buffer: [String] = []
    private static let maxBuffered = 512

    private static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Ampersand")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("diag.log")
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Periodic flush so buffered lines are not lost on a quiet buffer.
    private static let flushTimer: DispatchSourceTimer = {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { Diagnostics.flush() }
        timer.resume()
        return timer
    }()

    public static func log(_ message: String) {
        _ = flushTimer // start the periodic flush on first use
        let line = "\(timestamp()) \(message)"
        var shouldFlush = false
        lock.lock()
        buffer.append(line)
        shouldFlush = buffer.count >= maxBuffered
        lock.unlock()
        if shouldFlush { flush() }
    }

    /// Writes all buffered lines to the log file in one I/O.
    public static func flush() {
        lock.lock()
        let lines = buffer
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()
        guard !lines.isEmpty else { return }
        let payload = lines.joined(separator: "\n") + "\n"
        guard let data = payload.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    public static var logPath: String { logURL.path }

    /// Formatter is only touched while `lock` is held inside `log(_:)`.
    private static func timestamp() -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: Date())
    }
}
