import Foundation
import Protocol
import AndroidBridge
import Diagnostics

/// Thread-safe reference used by capture/input delivery callbacks. The
/// session controller remains the only owner that replaces the current
/// session; input delivery never reaches into AppModel for a mutable handle.
public struct SessionSnapshot: Sendable {
    public let connection: (any SessionConnection)?
    public let generation: UInt64
}

public final class SessionReference: @unchecked Sendable {
    public init() {}
    private let lock = NSLock()
    private var session: (any SessionConnection)?
    private var generation: UInt64 = 0

    /// Replacing or clearing the session advances the epoch. Queued input
    /// captures this value and can therefore never be redirected to a later
    /// connection.
    public func set(_ session: (any SessionConnection)?) {
        lock.withLock {
            self.session = session
            generation &+= 1
        }
    }

    public func snapshot() -> SessionSnapshot {
        lock.withLock { SessionSnapshot(connection: session, generation: generation) }
    }

    public func current() -> (any SessionConnection)? { snapshot().connection }
}


/// Owns connection/helper lifecycle, reconnect callbacks, and the current
/// CXI session. `SessionState` is mutated here; AppModel mirrors it only as
/// presentation-facing observable state.
@MainActor
public final class SessionController {
    private let adbTransport: AdbTransport
    let reference: SessionReference
    private(set) var state: SessionState = .disconnected

    public var onStateChange: ((SessionState) -> Void)?
    public var onEvent: ((CxiFrame) -> Void)?
    public var onUnavailable: ((String) -> Void)?

    /// Production telemetry sink (review round 2, P1-6): invoked with every
    /// completed request observation so the app can persist failure/late
    /// metadata. The app wires this to Diagnostics; without a sink nothing
    /// is recorded.
    /// Unified production telemetry sink (review round 3): receives request
    /// observations from RemoteSession AND semantic delivery observations
    /// from InputSender, plus late-response records. Lock-protected — invoked
    /// from arbitrary queues with no main-actor hop.
    /// Lock-guarded sink storage (review round 5): the box owns its own
    /// NSLock and is Sendable, so no `nonisolated(unsafe)` annotation is
    /// needed on controller state. The controller is MainActor-isolated;
    /// the box's methods are nonisolated and callable from any queue.
    let observationSinkBox = ObservationSinkBox()

    /// Composition-time registration of the unified telemetry sink.
    /// Receives transport request observations, InputSender delivery
    /// observations, and late responses.
    nonisolated public func setObservationSink(_ sink: (@Sendable (RequestObservation) -> Void)?) {
        observationSinkBox.set(sink)
    }

    /// Reads the current sink (used by forwarding helpers on arbitrary queues).
    nonisolated func currentObservationSink() -> (@Sendable (RequestObservation) -> Void)? {
        observationSinkBox.current()
    }

    /// Dispatches one delivery-layer observation through the registered sink.
    /// The app calls this when creating InputSender so pointer semantic
    /// failures (malformed/unexpected/helper-failure) reach diagnostics too.
    nonisolated public func forwardDeliveryObservation(_ observation: RequestObservation) {
        currentObservationSink()?(observation)
    }

    private var session: (any SessionConnection)?
    /// Candidate performing HELLO/capability negotiation. It is owned by the
    /// controller for cancellation, but is not published to InputSender until
    /// the handshake has completed successfully.
    private var connectingSession: (any SessionConnection)?
    private var connectionAttempt: UInt64 = 0
    private var reconnectTask: Task<Void, Never>?
    private let sessionFactory: @Sendable (RemoteSession.Configuration) -> any SessionConnection

    public init(adbTransport: AdbTransport = AdbTransport(),
                reference: SessionReference = SessionReference(),
                sessionFactory: @escaping @Sendable (RemoteSession.Configuration) -> any SessionConnection = { RemoteSession(configuration: $0) }) {
        self.adbTransport = adbTransport
        self.reference = reference
        self.sessionFactory = sessionFactory
    }

    public var isConnected: Bool { session?.isConnected == true }
    var currentSerial: String { session?.serial ?? "" }

    public func firstConnectedSerial() -> String { adbTransport.firstConnectedSerial() }

    public func connect(serial: String) async throws -> any SessionConnection {
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionAttempt &+= 1
        let attempt = connectionAttempt
        setState(.connecting)
        let old = session
        let oldConnecting = connectingSession
        session = nil
        connectingSession = nil
        reference.set(nil)
        old?.shutdownAndWait()
        oldConnecting?.shutdownAndWait()

        var configuration = RemoteSession.Configuration(transport: adbTransport, serial: serial)
        configuration.stderrHandler = { text in Diagnostics.log("helper: \(text)") }
        let manager = sessionFactory(configuration)
        manager.onEvent = { [weak self, weak manager] frame in
            Task { @MainActor in
                guard let self, let manager, self.session === manager else { return }
                self.onEvent?(frame)
            }
        }
        manager.onDisconnect = { [weak self, weak manager] in
            Task { @MainActor in
                guard let self, let manager, self.session === manager else { return }
                self.session = nil
                self.reference.set(nil)
                self.setState(.disconnected)
                self.onUnavailable?("helper session ended")
            }
        }
        connectingSession = manager

        do {
            try await manager.connect()
            guard attempt == connectionAttempt,
                  connectingSession === manager else {
                throw ConnectionError.streamClosed
            }
            connectingSession = nil
            session = manager
            if let remoteSession = manager as? RemoteSession {
                // The sink is invoked directly off the reader queue — no
                // main-actor hop on the hot path.
                remoteSession.onObservation = { [weak self] observation in
                    self?.currentObservationSink()?(observation)
                }
                remoteSession.onLateResponse = { [weak self] record in
                    // Late responses are surfaced as a synthetic failure-
                    // class observation so a single sink handles all layers.
                    self?.currentObservationSink()?(RequestObservation(
                        kind: record.requestKind,
                        outcome: .lateResponse(requestKind: record.requestKind,
                                              delayBeyondTimeout: record.delayBeyondTimeout)))
                }
            }
            reference.set(manager)
            setState(.ready)
            return manager
        } catch {
            if attempt == connectionAttempt, connectingSession === manager {
                connectingSession = nil
                reference.set(nil)
                setState(.failed(error.localizedDescription))
            }
            // A newer attempt may already have shut this candidate down. If
            // the stale connect nevertheless became live, close it here.
            if attempt == connectionAttempt || manager.isConnected {
                manager.shutdownAndWait()
            }
            throw error
        }
    }

    public func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionAttempt &+= 1
        let old = session
        let oldConnecting = connectingSession
        session = nil
        connectingSession = nil
        reference.set(nil)
        old?.shutdownAndWait()
        oldConnecting?.shutdownAndWait()
        setState(.disconnected)
    }

    /// Moves the session to a failed terminal state and tears down any helper
    /// candidate or live channel so presentation and transport cannot diverge.
    public func fail(_ message: String) {
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionAttempt &+= 1
        let old = session
        let oldConnecting = connectingSession
        session = nil
        connectingSession = nil
        reference.set(nil)
        old?.shutdownAndWait()
        oldConnecting?.shutdownAndWait()
        setState(.failed(message))
    }

    func markReconnecting() {
        setState(.reconnecting)
    }

    /// Owns wireless endpoint discovery and reconnect attempts. The caller
    /// supplies only the application-level action to run after a live serial
    /// is found; ADB syntax and retry policy stay inside the session layer.
    public func scheduleAutoReconnect(
        serial: String,
        onConnected: @escaping @MainActor @Sendable (String) async -> Void
    ) {
        reconnectTask?.cancel()
        guard serial.contains(":") else {
            Diagnostics.log("auto-reconnect skipped (serial: \(serial.isEmpty ? "none" : "usb"))")
            return
        }

        setState(.reconnecting)
        let transport = adbTransport
        let remembered = serial
        reconnectTask = Task.detached { [weak self] in
            for attempt in 1...5 {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled, let self else { return }
                guard await !self.isConnected else { return }

                let endpoints = transport.discoverWirelessEndpoints(target: remembered)
                for endpoint in endpoints {
                    transport.reconnect(serial: endpoint)
                }
                let found = transport.firstConnectedSerial()
                if !found.isEmpty {
                    await onConnected(found)
                    return
                }
                Diagnostics.log("auto-reconnect attempt \(attempt): device still offline")
            }
            guard !Task.isCancelled, let self else { return }
            await self.fail("Wireless device remained unavailable after 5 reconnect attempts")
        }
    }

    private func setState(_ state: SessionState) {
        self.state = state
        if ProcessInfo.processInfo.environment["CROSSINPUT_DIAG_CURSOR_VISIBILITY"] == "1" {
            Diagnostics.log("cursor investigation session-state=\(Self.diagnosticName(state))")
        }
        onStateChange?(state)
    }

    private static func diagnosticName(_ state: SessionState) -> String {
        switch state {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .ready: return "ready"
        case .reconnecting: return "reconnecting"
        case .failed: return "failed"
        }
    }
}
