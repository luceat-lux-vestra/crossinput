import Foundation
import Protocol
import AndroidBridge
import Diagnostics

/// Thread-safe reference used by capture/input delivery callbacks. The
/// session controller remains the only owner that replaces the current
/// session; input delivery never reaches into AppModel for a mutable handle.
struct SessionSnapshot: Sendable {
    let connection: (any SessionConnection)?
    let generation: UInt64
}

final class SessionReference: @unchecked Sendable {
    private let lock = NSLock()
    private var session: (any SessionConnection)?
    private var generation: UInt64 = 0

    /// Replacing or clearing the session advances the epoch. Queued input
    /// captures this value and can therefore never be redirected to a later
    /// connection.
    func set(_ session: (any SessionConnection)?) {
        lock.withLock {
            self.session = session
            generation &+= 1
        }
    }

    func snapshot() -> SessionSnapshot {
        lock.withLock { SessionSnapshot(connection: session, generation: generation) }
    }

    func current() -> (any SessionConnection)? { snapshot().connection }
}

/// Owns connection/helper lifecycle, reconnect callbacks, and the current
/// CXI session. `SessionState` is mutated here; AppModel mirrors it only as
/// presentation-facing observable state.
@MainActor
final class SessionController {
    private let adbTransport: AdbTransport
    let reference: SessionReference
    private(set) var state: SessionState = .disconnected

    var onStateChange: ((SessionState) -> Void)?
    var onEvent: ((CxiFrame) -> Void)?
    var onUnavailable: ((String) -> Void)?

    private var session: (any SessionConnection)?
    private var reconnectTask: Task<Void, Never>?
    private let sessionFactory: @Sendable (RemoteSession.Configuration) -> any SessionConnection

    init(adbTransport: AdbTransport = AdbTransport(),
         reference: SessionReference = SessionReference(),
         sessionFactory: @escaping @Sendable (RemoteSession.Configuration) -> any SessionConnection = { RemoteSession(configuration: $0) }) {
        self.adbTransport = adbTransport
        self.reference = reference
        self.sessionFactory = sessionFactory
    }

    var isConnected: Bool { session?.isConnected == true }
    var currentSerial: String { session?.serial ?? "" }

    func firstConnectedSerial() -> String { adbTransport.firstConnectedSerial() }

    func connect(serial: String) async throws -> any SessionConnection {
        reconnectTask?.cancel()
        reconnectTask = nil
        setState(.connecting)
        let old = session
        session = nil
        reference.set(nil)
        old?.shutdownAndWait()

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
        session = manager
        reference.set(manager)

        do {
            try await manager.connect()
            guard session === manager else { throw ConnectionError.streamClosed }
            setState(.ready)
            return manager
        } catch {
            if session === manager {
                session = nil
                reference.set(nil)
                setState(.failed(error.localizedDescription))
            }
            throw error
        }
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        let old = session
        session = nil
        reference.set(nil)
        old?.shutdownAndWait()
        setState(.disconnected)
    }

    func markFailed(_ message: String) {
        setState(.failed(message))
    }

    func markReconnecting() {
        setState(.reconnecting)
    }

    /// Owns wireless endpoint discovery and reconnect attempts. The caller
    /// supplies only the application-level action to run after a live serial
    /// is found; ADB syntax and retry policy stay inside the session layer.
    func scheduleAutoReconnect(
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
        }
    }

    private func setState(_ state: SessionState) {
        self.state = state
        onStateChange?(state)
    }
}
