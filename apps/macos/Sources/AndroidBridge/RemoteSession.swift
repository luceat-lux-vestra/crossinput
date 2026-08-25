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
    case incompatibleHelper(String)
}

extension ConnectionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .adbMissing: return "ADB executable is unavailable"
        case let .processSpawnFailed(message): return "Unable to start helper: \(message)"
        case let .processExited(code): return "Helper exited with code \(code)"
        case let .handshakeFailed(message): return "Helper handshake failed: \(message)"
        case let .timeout(message): return "Helper request timed out: \(message)"
        case .streamClosed: return "Helper stream closed"
        case let .protocolError(message): return "Helper protocol error: \(message)"
        case let .incompatibleHelper(message): return "Incompatible helper: \(message)"
        }
    }
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
///
/// Issue #62 observability: every completed request yields a metadata-only
/// `RequestObservation` (outcome taxonomy, latency), and responses arriving
/// for already-timed-out requests are classified as LATE through bounded
/// `TimeoutTombstones` instead of being silently forwarded as uncorrelated
/// events. No input payload ever enters an observation.
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
    public private(set) var helperCapabilities: HelperCapabilities = []
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

    /// Metadata-only diagnostics (issue #62). `onObservation` fires once per
    /// completed request from arbitrary queues; `lateResponses` accumulates on
    /// `readerQueue` behind `lateLock`, capped at `maxLateResponses` (oldest
    /// dropped first). Read it via `snapshotLateResponses()`.
    public var onObservation: (@Sendable (RequestObservation) -> Void)?
    public let timeoutTombstones = TimeoutTombstones()

    /// Cap on retained late-response records (review fix: unbounded growth
    /// in long sessions is a memory leak; diagnostics need only a bounded
    /// window).
    public static let maxLateResponses = 256

    /// Production sink for late responses (review round 3): invoked from the
    /// reader queue when a response arrives after its requester timed out.
    /// Without this, a field "timeout vs valid result after deadline" event
    /// never reaches diagnostics.
    public var onLateResponse: (@Sendable (LateResponseRecord) -> Void)?
    private let lateLock = NSLock()
    private var _lateResponses: [LateResponseRecord] = []

    /// Synchronized snapshot of retained late-response records.
    public func snapshotLateResponses() -> [LateResponseRecord] {
        lateLock.withLock { _lateResponses }
    }

    /// Test seam: injects the monotonic microsecond clock.
    var nowMicros: @Sendable () -> Int64 = { Int64(DispatchTime.now().uptimeNanoseconds) / 1_000 }

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
            helperCapabilities = try Self.validateHelloAck(ack)
        } catch {
            await disconnect()
            throw error
        }
    }

    /// Sends a request frame and awaits the matching response.
    public func request(_ type: MessageType, payload: Data,
                        timeout: TimeInterval? = nil) async throws -> CxiFrame {
        let startedMicros = nowMicros()
        do {
            let frame = try await requestUncounted(type, payload: payload, timeout: timeout)
            let elapsed = Double(nowMicros() - startedMicros) / 1_000_000
            emit(RequestObservation(kind: RequestObservation.Kind(of: type),
                                    outcome: .success(elapsed: elapsed)))
            return frame
        } catch let error as ConnectionError {
            emit(Self.observation(for: error,
                                  requestType: RequestObservation.Kind(of: type),
                                  timeoutBudget: timeout ?? config.requestTimeout))
            throw error
        } catch {
            emit(RequestObservation(
                kind: RequestObservation.Kind(of: type),
                outcome: .otherFailure(requestType: RequestObservation.Kind(of: type),
                                       errorDescription: String(describing: error))))
            throw error
        }
    }

    /// Core request path without observation bookkeeping, so the public
    /// `request` wraps exactly one observation per completed request.
    private func requestUncounted(_ type: MessageType, payload: Data,
                                  timeout: TimeInterval?) async throws -> CxiFrame {
        try await withCheckedThrowingContinuation { continuation in
            let id = allocateRequestId()
            let deadline = timeout ?? config.requestTimeout
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let kind = RequestObservation.Kind(of: type)
                // Atomic eviction + tombstone (review fix, round 2): the
                // tombstone is recorded ONLY when the timeout actually wins
                // the race (removed != nil). If a response already evicted
                // the entry, that request succeeded — recording a tombstone
                // would let a subsequent same-id response be misclassified
                // as LATE. Holding pendingLock across both operations keeps
                // eviction and tombstone indivisible; dispatch's removal
                // runs on readerQueue under the same lock, so ordering is
                // total and exactly one side wins per request id.
                self.pendingLock.withLock {
                    guard let removed = self.pending.removeValue(forKey: id) else {
                        return // response won: request already succeeded
                    }
                    self.timeoutTombstones.record(
                        id: id,
                        requestKind: kind,
                        timeoutBudget: deadline,
                        nowMonotonicMicros: self.nowMicros())
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
                pendingLock.withLock { _ = pending.removeValue(forKey: id) }
                workItem.cancel()
                continuation.resume(throwing: error)
            }
        }
    }

    private func emit(_ observation: RequestObservation) {
        onObservation?(observation)
    }

    /// Maps a request-path `ConnectionError` onto the investigation taxonomy.
    public static func observation(for error: ConnectionError,
                                   requestType: RequestObservation.Kind,
                                   timeoutBudget: Double) -> RequestObservation {
        let outcome: RequestObservation.Outcome
        switch error {
        case .timeout:
            outcome = .timedOut(requestType: requestType, timeoutBudget: timeoutBudget)
        case .streamClosed:
            outcome = .streamClosed(requestType: requestType)
        default:
            outcome = .writeFailed(requestType: requestType)
        }
        return RequestObservation(kind: requestType, outcome: outcome)
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

    static func validateHelloAck(_ ack: CxiFrame) throws -> HelperCapabilities {
        guard ack.type == .helloAck else {
            throw ConnectionError.handshakeFailed("expected HELLO_ACK, got \(ack.type)")
        }
        let info = try Messages.decodeHelloAckInfo(ack.payload)
        guard info.version == Protocol.version else {
            throw ConnectionError.handshakeFailed("expected v\(Protocol.version), got v\(info.version)")
        }
        let required: [HelperCapabilities] = [
            .semanticPointerResult,
            .explicitPointerRouting,
        ]
        let missing = required.filter { !info.capabilities.contains($0) }
        guard missing.isEmpty else {
            let names = missing.map { capabilityName($0) }.joined(separator: ", ")
            throw ConnectionError.incompatibleHelper("missing capability: \(names)")
        }
        return info.capabilities
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
            // The requester is gone. A recent timeout tombstone classifies
            // this as a LATE response (the helper did answer, just after the
            // deadline); no tombstone means genuinely uncorrelated.
            recordLateResponseIfTimedOut(frame)
            onEvent?(frame)
        }
    }

    /// Runs on `readerQueue` only, so append order is stable; the lock makes
    /// the bounded buffer safe against cross-queue snapshots.
    private func recordLateResponseIfTimedOut(_ frame: CxiFrame) {
        guard let record = timeoutTombstones.consume(
            id: frame.requestId,
            at: nowMicros()) else { return }
        lateLock.withLock {
            _lateResponses.append(record)
            if _lateResponses.count > Self.maxLateResponses {
                _lateResponses.removeFirst(_lateResponses.count - Self.maxLateResponses)
            }
        }
        onLateResponse?(record)
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

    private static func capabilityName(_ capability: HelperCapabilities) -> String {
        switch capability {
        case .semanticPointerResult: return "semanticPointerResult"
        case .explicitPointerRouting: return "explicitPointerRouting"
        default: return "unknown"
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
