@preconcurrency import Dispatch
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
/// Threading contract:
/// - `log(_:)` is called on the event-tap thread; it only acquires the buffer
///   lock to append a line and snapshot the buffer when it fills. The current
///   thread never touches the file.
/// - The writer queue is the only owner of the `FileHandle`; every snapshot is
///   appended serially so concurrent flushes cannot interleave or lose lines.
/// - `flushSync()` blocks until every snapshot enqueued before it is written
///   (used by app teardown and tests).
public enum Diagnostics {
    /// Test hook: where the log file is written. Defaults to
    /// `~/Library/Logs/Ampersand/diag.log`.
    nonisolated(unsafe) public static var logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Ampersand")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("diag.log")
    }()

    private static let lock = NSLock()
    nonisolated(unsafe) private static var buffer: [String] = []
    private static let flushThreshold = 512

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Serial writer: the only owner of the log FileHandle. Each flush hands a
    /// snapshot to this queue, preserving order and preventing data races.
    private static let writerQueue = DispatchQueue(label: "io.ampersand.diagnostics.writer")

    /// Periodic flush so buffered lines are not lost on a quiet buffer.
    private static let flushTimer: DispatchSourceTimer = {
        let timer = DispatchSource.makeTimerSource(queue: writerQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { Diagnostics.flush() }
        timer.resume()
        return timer
    }()

    nonisolated(unsafe) private static var hasStarted: Bool = false

    public static func log(_ message: String) {
        maybeEmitIdentityMarker()
        // Start the periodic flush on first use (cheap, idempotent).
        lock.lock()
        let startTimer = !hasStarted
        hasStarted = true
        lock.unlock()
        if startTimer { _ = flushTimer }
        let line = formattedLine(message)
        var shouldFlush = false
        lock.lock()
        buffer.append(line)
        shouldFlush = buffer.count >= flushThreshold
        lock.unlock()
        if shouldFlush { flush() }
    }

    /// Emits the candidate-identity marker exactly once per process, ordered
    /// before every ordinary log line (ADR-0012 candidate-identity
    /// requirement). The guard read, flag transition, and marker append all
    /// run in ONE critical section of `lock`, so concurrent first `log(_:)`
    /// calls cannot interleave: exactly one marker is written and every
    /// ordinary line lands strictly after it. `formattedLine` also takes
    /// `lock` (NSLock is not reentrant), so the stamp is computed BEFORE
    /// entering the critical section. Metadata only.
    private static func maybeEmitIdentityMarker() {
        let line = formattedLine(CandidateIdentity.diagnosticMarker)
        lock.lock()
        let alreadyEmitted = identityMarkerEmitted
        if !alreadyEmitted {
            identityMarkerEmitted = true
            buffer.append(line)
        }
        lock.unlock()
        // The marker must reach disk immediately: it attributes every later
        // line in this window. flush() takes the same non-reentrant lock, so
        // it MUST run only after the critical section above has released it.
        if !alreadyEmitted { flush() }
    }

    nonisolated(unsafe) private static var identityMarkerEmitted: Bool = false

    /// Test-only: resets the exactly-once marker so each test gets a fresh
    /// process-identity window. Never call from production code.
    static func resetIdentityMarkerForTesting() {
        lock.lock()
        identityMarkerEmitted = false
        // Drain anything buffered by earlier suites so this window starts
        // with the marker as the literal first line.
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// Snapshots the buffer and hands it to the serial writer queue.
    /// Returns immediately; the current thread never performs file I/O.
    public static func flush() {
        let lines: [String]
        lock.lock()
        guard !buffer.isEmpty else {
            lock.unlock()
            return
        }
        lines = buffer
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()

        writerQueue.async {
            append(lines)
        }
    }

    /// Flushes the current buffer, then blocks until every snapshot handed to
    /// the writer queue has been appended to the file. Used at app teardown
    /// and in tests to guarantee the last log line is durable before checking
    /// the file.
    public static func flushSync() {
        flush()
        writerQueue.sync {}
    }

    public static var logPath: String { logURL.path }

    // MARK: - Internal

    private static func formattedLine(_ message: String) -> String {
        let stamp: String
        lock.lock()
        stamp = formatter.string(from: Date())
        lock.unlock()
        return "\(stamp) \(message)"
    }

    /// Runs only on writerQueue; the sole writer of the log file.
    private static func append(_ lines: [String]) {
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
}