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

/// Transport-independent session surface used by the macOS orchestration
/// layer. Tests can exercise stale callback and replacement behavior without
/// starting ADB.
public protocol SessionConnection: AnyObject, Sendable {
    var serial: String { get }
    var isConnected: Bool { get }
    var onEvent: (@Sendable (CxiFrame) -> Void)? { get set }
    var onDisconnect: (@Sendable () -> Void)? { get set }

    func connect() async throws
    func request(_ type: MessageType, payload: Data, timeout: TimeInterval?) async throws -> CxiFrame
    func send(_ frame: CxiFrame) throws
    func shutdownAndWait()
}

public extension SessionConnection {
    func request(_ type: MessageType, payload: Data) async throws -> CxiFrame {
        try await request(type, payload: payload, timeout: nil)
    }

    /// Synchronous delivery seam for the capture queue. The capture callback
    /// must not credit movement before the helper's pointer-result response,
    /// while the main actor remains free to process the response stream.
    func requestBlocking(_ type: MessageType,
                         payload: Data,
                         timeout: TimeInterval? = nil) throws -> CxiFrame {
        let result = BlockingRequestResult()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                result.set(.success(try await request(type, payload: payload, timeout: timeout)))
            } catch {
                result.set(.failure(error))
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }
}

private final class BlockingRequestResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<CxiFrame, Error>?

    func set(_ value: Result<CxiFrame, Error>) {
        lock.withLock { self.value = value }
    }

    func get() throws -> CxiFrame {
        try lock.withLock {
            guard let value else { throw ConnectionError.streamClosed }
            return try value.get()
        }
    }
}

/// Owns the CXI handshake, request correlation, event dispatch, and timeouts.
/// ADB process and byte-stream ownership belongs to `AdbTransport`.
public final class RemoteSession: SessionConnection, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var transport: AdbTransport
        public var serial: String
        public var apkPath: String
        public var helperClass: String
        public var requestTimeout: TimeInterval
        public var handshakeTimeout: TimeInterval
        public var stderrHandler: (@Sendable (String) -> Void)?

        public init(transport: AdbTransport = AdbTransport(),
                    serial: String,
                    apkPath: String = "/data/local/tmp/crossinput-helper.apk",
                    helperClass: String = "/ com.crossinput.helper.Main",
                    requestTimeout: TimeInterval = 5,
                    handshakeTimeout: TimeInterval = 10,
                    stderrHandler: (@Sendable (String) -> Void)? = nil) {
            self.transport = transport
            self.serial = serial
            self.apkPath = apkPath
            self.helperClass = helperClass
            self.requestTimeout = requestTimeout
            self.handshakeTimeout = handshakeTimeout
            self.stderrHandler = stderrHandler
        }

        /// Compatibility property for the v1 smoke tool. New application code
        /// supplies an `AdbTransport` at the composition root.
        @available(*, deprecated, renamed: "transport")
        public var adbPath: String {
            get { transport.configuredPath ?? AdbTransport.locate() ?? "/usr/local/bin/adb" }
            set { transport = AdbTransport(path: newValue) }
        }
    }

    public private(set) var serial: String
    public var onEvent: (@Sendable (CxiFrame) -> Void)?
    public var onDisconnect: (@Sendable () -> Void)?

    private let config: Configuration
    private let channelLock = NSLock()
    private var channel: AdbTransport.Channel?
    private let writeLock = NSLock()
    private let pendingLock = NSLock()
    private var pending: [UInt32: PendingRequest] = [:]
    private var nextRequestId: UInt32 = 1
    private var parser = FrameParser()
    private let readerQueue = DispatchQueue(label: "crossinput.reader")

    private struct PendingRequest {
        let continuation: CheckedContinuation<CxiFrame, Error>
        let timeout: DispatchWorkItem
    }

    public init(configuration: Configuration) {
        self.config = configuration
        self.serial = configuration.serial
    }

    public var isConnected: Bool {
        channelLock.withLock { channel?.isRunning == true }
    }

    /// Starts the ADB-owned helper channel and performs the CXI HELLO handshake.
    public func connect() async throws {
        guard !isConnected else { return }
        let transportConfig = AdbTransport.LaunchConfiguration(
            serial: config.serial,
            apkPath: config.apkPath,
            helperClass: config.helperClass,
            stderrHandler: config.stderrHandler ?? { text in
                NSLog("[crossinput:helper] %@", text)
            },
            terminationHandler: { [weak self] in
                self?.handleStreamClosed()
            })
        let newChannel: AdbTransport.Channel
        do {
            newChannel = try config.transport.launch(transportConfig)
        } catch AdbTransportError.adbMissing {
            throw ConnectionError.adbMissing
        } catch AdbTransportError.processSpawnFailed(let message) {
            throw ConnectionError.processSpawnFailed(message)
        } catch {
            throw ConnectionError.processSpawnFailed(error.localizedDescription)
        }
        channelLock.withLock { channel = newChannel }

        newChannel.output.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                self.handleStreamClosed()
                return
            }
            self.readerQueue.async { self.consume(data) }
        }

        do {
            let ack = try await request(.hello, payload: Messages.hello(), timeout: config.handshakeTimeout)
            guard ack.type == .helloAck else {
                throw ConnectionError.handshakeFailed("expected HELLO_ACK, got \(ack.type)")
            }
        } catch {
            await disconnect()
            throw error
        }
    }

    /// Sends a request frame and awaits the matching response.
    public func request(_ type: MessageType, payload: Data,
                        timeout: TimeInterval? = nil) async throws -> CxiFrame {
        try await withCheckedThrowingContinuation { continuation in
            let id = allocateRequestId()
            let deadline = timeout ?? config.requestTimeout
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let removed = self.pendingLock.withLock { self.pending.removeValue(forKey: id) }
                removed?.continuation.resume(throwing: ConnectionError.timeout("no response to \(type) (req \(id))"))
            }
            pendingLock.withLock {
                pending[id] = PendingRequest(continuation: continuation, timeout: workItem)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + deadline, execute: workItem)
            do {
                try writeFrame(CxiFrame(type: type, requestId: id, payload: payload))
            } catch {
                pendingLock.withLock { _ = pending.removeValue(forKey: id) }
                workItem.cancel()
                continuation.resume(throwing: error)
            }
        }
    }

    /// Sends a fire-and-forget semantic or compatibility frame.
    public func send(_ frame: CxiFrame) throws {
        try writeFrame(frame)
    }

    /// Best-effort SHUTDOWN followed by transport-owned channel cleanup.
    public func shutdownAndWait() {
        guard isConnected else { return }
        _ = try? writeFrame(CxiFrame(type: .shutdown, requestId: allocateRequestId()))
        Thread.sleep(forTimeInterval: 1)
        disconnectSync()
    }

    public func disconnect() async {
        disconnectSync()
    }

    private func disconnectSync() {
        let current = channelLock.withLock { () -> AdbTransport.Channel? in
            let value = channel
            channel = nil
            return value
        }
        current?.output.readabilityHandler = nil
        current?.error.readabilityHandler = nil
        current?.close()
        failAllPending(ConnectionError.streamClosed)
    }

    private func handleStreamClosed() {
        failAllPending(ConnectionError.streamClosed)
        onDisconnect?()
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
        guard let input = channelLock.withLock({ channel?.input }) else {
            throw ConnectionError.streamClosed
        }
        let data = encode(frame)
        writeLock.withLock { input.write(data) }
    }

    private func consume(_ data: Data) {
        for frame in parser.append(data) { dispatch(frame) }
    }

    private func dispatch(_ frame: CxiFrame) {
        guard !frame.type.isRequest else {
            onEvent?(frame)
            return
        }
        let pendingRequest = pendingLock.withLock { () -> PendingRequest? in
            guard let request = pending.removeValue(forKey: frame.requestId) else { return nil }
            request.timeout.cancel()
            return request
        }
        if let pendingRequest {
            pendingRequest.continuation.resume(returning: frame)
        } else {
            onEvent?(frame)
        }
    }

    private func failAllPending(_ error: Error) {
        let all = pendingLock.withLock { () -> [PendingRequest] in
            let values = Array(pending.values)
            pending.removeAll()
            return values
        }
        for request in all {
            request.timeout.cancel()
            request.continuation.resume(throwing: error)
        }
    }
}

/// Compatibility name for clients from before the architecture rebaseline.
@available(*, deprecated, renamed: "RemoteSession")
public typealias ConnectionManager = RemoteSession

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
