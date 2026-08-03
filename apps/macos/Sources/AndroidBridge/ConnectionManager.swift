import Foundation
import Protocol

public enum ConnectionError: Error, Sendable {
    case adbMissing
    case processSpawnFailed(String)
    case processExited(code: Int32)
    case handshakeFailed(String)
    case timeout(String)
    case streamClosed
    case protocolError(String)
}

/// ConnectionManager owns the adb subprocess running the Android helper and
/// implements the CXI request/response layer over its stdin/stdout.
///
/// Transport: `adb -s SERIAL shell -T "app_process -cp ..."` with PTY disabled
/// so the channel is binary-safe (same pattern scrcpy uses for its server).
public final class ConnectionManager: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var adbPath: String
        public var serial: String
        public var apkPath: String
        public var helperClass: String
        public var requestTimeout: TimeInterval
        public var handshakeTimeout: TimeInterval
        public var stderrHandler: (@Sendable (String) -> Void)?

        public init(adbPath: String = "/usr/local/bin/adb",
                    serial: String,
                    apkPath: String = "/data/local/tmp/crossinput-helper.apk",
                    helperClass: String = "/ com.crossinput.helper.Main",
                    requestTimeout: TimeInterval = 5,
                    handshakeTimeout: TimeInterval = 10,
                    stderrHandler: (@Sendable (String) -> Void)? = nil) {
            self.adbPath = adbPath
            self.serial = serial
            self.apkPath = apkPath
            self.helperClass = helperClass
            self.requestTimeout = requestTimeout
            self.handshakeTimeout = handshakeTimeout
            self.stderrHandler = stderrHandler
        }
    }

    public private(set) var serial: String
    public var onEvent: (@Sendable (CxiFrame) -> Void)?
    public var onDisconnect: (@Sendable () -> Void)?

    private let config: Configuration
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private let writeLock = NSLock()
    private let pendingLock = NSLock()
    private var pending: [UInt32: PendingRequest] = [:]
    private var nextRequestId: UInt32 = 1
    private var parser = FrameParser()
    private var readerQueue = DispatchQueue(label: "crossinput.reader")
    private var started = false

    private struct PendingRequest {
        let continuation: CheckedContinuation<CxiFrame, Error>
        let timeout: DispatchWorkItem
    }

    public init(configuration: Configuration) {
        self.config = configuration
        self.serial = configuration.serial
    }

    public var isConnected: Bool {
        process?.isRunning == true
    }

    /// Spawns the helper via adb and performs the HELLO handshake.
    public func connect() async throws {
        guard !isConnected else { return }
        let adb = config.adbPath
        guard FileManager.default.isExecutableFile(atPath: adb) else {
            throw ConnectionError.adbMissing
        }
        // Clean up stale helper processes from previous sessions (repeated
        // Connect clicks left orphans). Bracket pattern avoids killing the
        // adb shell running THIS command.
        let cleanup = Process()
        cleanup.executableURL = URL(fileURLWithPath: adb)
        cleanup.arguments = ["-s", config.serial, "shell",
                             "pkill -f 'crossinput-[h]elper.apk' 2>/dev/null || true"]
        try? cleanup.run()
        cleanup.waitUntilExit()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: adb)
        proc.arguments = ["-s", config.serial, "shell", "-T",
                          "app_process", "-cp", config.apkPath, config.helperClass]
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        proc.standardInput = inputPipe
        proc.standardOutput = outputPipe
        proc.standardError = errorPipe
        proc.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.failAllPending(ConnectionError.streamClosed)
            self.onDisconnect?()
        }
        do {
            try proc.run()
        } catch {
            throw ConnectionError.processSpawnFailed(error.localizedDescription)
        }
        process = proc
        inputHandle = inputPipe.fileHandleForWriting
        outputHandle = outputPipe.fileHandleForReading

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty {
                // Log metadata only (AGENTS.md hard rule 4); stderr is the helper's log.
                let text = String(decoding: data, as: UTF8.self)
                if let handler = self?.config.stderrHandler {
                    handler(text.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    NSLog("[crossinput:helper] %@", text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }

        outputHandle?.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else {
                // EOF: helper exited.
                self.outputHandle?.readabilityHandler = nil
                self.failAllPending(ConnectionError.streamClosed)
                self.onDisconnect?()
                return
            }
            self.readerQueue.async {
                self.consume(data)
            }
        }

        do {
            let ack = try await request(MessageType.hello, payload: Messages.hello(),
                                        timeout: config.handshakeTimeout)
            guard ack.type == .helloAck else {
                throw ConnectionError.handshakeFailed("expected HELLO_ACK, got \(ack.type)")
            }
        } catch {
            await disconnect()
            throw error
        }
    }

    /// Sends a request frame and awaits the matching response (same requestId).
    public func request(_ type: MessageType, payload: Data,
                        timeout: TimeInterval? = nil) async throws -> CxiFrame {
        try await withCheckedThrowingContinuation { continuation in
            let id = allocateRequestId()
            let deadline = timeout ?? config.requestTimeout
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let removed = self.pendingLock.withLock {
                    self.pending.removeValue(forKey: id)
                }
                if let removed {
                    removed.continuation.resume(throwing: ConnectionError.timeout("no response to \(type) (req \(id))"))
                }
            }
            pendingLock.withLock {
                pending[id] = PendingRequest(continuation: continuation, timeout: workItem)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + deadline, execute: workItem)
            do {
                try writeFrame(CxiFrame(type: type, requestId: id, payload: payload))
            } catch {
                pendingLock.withLock {
                    _ = pending.removeValue(forKey: id)
                }
                workItem.cancel()
                continuation.resume(throwing: error)
            }
        }
    }

    public func send(_ frame: CxiFrame) throws {
        try writeFrame(frame)
    }

    /// Best-effort shutdown: SHUTDOWN frame then terminate the subprocess.
    public func shutdownAndWait() {
        guard isConnected else { return }
        _ = try? writeFrame(CxiFrame(type: .shutdown, requestId: allocateRequestId()))
        // Give the helper a moment to exit cleanly, then terminate regardless.
        Thread.sleep(forTimeInterval: 1)
        disconnectSync()
    }

    public func disconnect() async {
        disconnectSync()
    }

    private func disconnectSync() {
        let proc = process
        process = nil
        outputHandle?.readabilityHandler = nil
        inputHandle = nil
        outputHandle = nil
        if proc?.isRunning == true {
            proc?.terminate()
        }
        failAllPending(ConnectionError.streamClosed)
    }

    // MARK: - Internals

    private func allocateRequestId() -> UInt32 {
        writeLock.withLock {
            let id = nextRequestId
            nextRequestId &+= 1
            return id
        }
    }

    private func writeFrame(_ frame: CxiFrame) throws {
        guard let handle = inputHandle else { throw ConnectionError.streamClosed }
        let data = encode(frame)
        writeLock.withLock {
            handle.write(data)
        }
    }

    private func consume(_ data: Data) {
        for frame in parser.append(data) {
            dispatch(frame)
        }
    }

    private func dispatch(_ frame: CxiFrame) {
        guard !frame.type.isRequest else {
            // A request arriving from the helper is unexpected in v1.
            onEvent?(frame)
            return
        }
        let pendingRequest = pendingLock.withLock { () -> PendingRequest? in
            if let req = pending.removeValue(forKey: frame.requestId) {
                req.timeout.cancel()
                return req
            }
            return nil
        }
        if let pendingRequest {
            pendingRequest.continuation.resume(returning: frame)
        } else {
            // Unsolicited responses (LOG_EVENT, DISPLAY_CHANGED, FATAL_ERROR...).
            onEvent?(frame)
        }
    }

    private func failAllPending(_ error: Error) {
        let all = pendingLock.withLock { () -> [PendingRequest] in
            let values = Array(pending.values)
            pending.removeAll()
            return values
        }
        for req in all {
            req.timeout.cancel()
            req.continuation.resume(throwing: error)
        }
    }
}

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
