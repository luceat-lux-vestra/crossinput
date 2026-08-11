import XCTest
@testable import App
import AndroidBridge
import Protocol

@MainActor
final class SessionControllerTests: XCTestCase {
    func testReconnectWhileLocalReplacesSessionAndIgnoresStaleDisconnect() async throws {
        let first = FakeSession(serial: "first")
        let second = FakeSession(serial: "second")
        let factory = SessionFactoryBox([first, second])
        let controller = SessionController(sessionFactory: { _ in factory.next() })

        _ = try await controller.connect(serial: "first")
        _ = try await controller.connect(serial: "second")
        first.triggerDisconnect()
        await Task.yield()

        XCTAssertEqual(controller.state, SessionState.ready)
        XCTAssertTrue(controller.reference.current() === second)
        XCTAssertEqual(first.shutdownCount, 1)
    }

    func testFailedHandshakeDoesNotLeaveACurrentSession() async {
        let failed = FakeSession(serial: "failed", connectError: FakeError.handshake)
        let factory = SessionFactoryBox([failed])
        let controller = SessionController(sessionFactory: { _ in factory.next() })

        do {
            _ = try await controller.connect(serial: "failed")
            XCTFail("expected the fake handshake to fail")
        } catch {
            XCTAssertEqual(controller.state, SessionState.failed(FakeError.handshake.localizedDescription))
            XCTAssertNil(controller.reference.current())
        }
    }

    func testSessionDisconnectWhileLocalClearsCurrentSessionAndRequestsRecovery() async throws {
        let session = FakeSession(serial: "device")
        let factory = SessionFactoryBox([session])
        let controller = SessionController(sessionFactory: { _ in factory.next() })
        var unavailableReason: String?
        controller.onUnavailable = { unavailableReason = $0 }

        _ = try await controller.connect(serial: "device")
        session.triggerDisconnect()
        await Task.yield()

        XCTAssertEqual(controller.state, SessionState.disconnected)
        XCTAssertNil(controller.reference.current())
        XCTAssertEqual(unavailableReason, "helper session ended")
    }

    func testReplacedSessionEventIsIgnoredWhileCurrentSessionEventIsAccepted() async throws {
        let first = FakeSession(serial: "first")
        let second = FakeSession(serial: "second")
        let factory = SessionFactoryBox([first, second])
        let controller = SessionController(sessionFactory: { _ in factory.next() })
        var received: [MessageType] = []
        controller.onEvent = { frame in received.append(frame.type) }

        _ = try await controller.connect(serial: "first")
        _ = try await controller.connect(serial: "second")

        first.triggerEvent(CxiFrame(type: .displayChanged, requestId: 1))
        first.triggerEvent(CxiFrame(type: .fatalError, requestId: 2))
        second.triggerEvent(CxiFrame(type: .logEvent, requestId: 3))
        for _ in 0..<3 { await Task.yield() }

        XCTAssertEqual(received, [.logEvent])
    }

    private final class SessionFactoryBox: @unchecked Sendable {
        private let lock = NSLock()
        private var sessions: [FakeSession]

        init(_ sessions: [FakeSession]) {
            self.sessions = sessions
        }

        func next() -> any SessionConnection {
            lock.lock()
            defer { lock.unlock() }
            return sessions.removeFirst()
        }
    }

    private final class FakeSession: SessionConnection, @unchecked Sendable {
        let serial: String
        let connectError: Error?
        var isConnected = false
        var onEvent: (@Sendable (CxiFrame) -> Void)?
        var onDisconnect: (@Sendable () -> Void)?
        var shutdownCount = 0

        init(serial: String, connectError: Error? = nil) {
            self.serial = serial
            self.connectError = connectError
        }

        func connect() async throws {
            if let connectError { throw connectError }
            isConnected = true
        }

        func request(_ type: MessageType, payload: Data, timeout: TimeInterval?) async throws -> CxiFrame {
            throw ConnectionError.streamClosed
        }

        func send(_ frame: CxiFrame) throws {
            guard isConnected else { throw ConnectionError.streamClosed }
        }

        func shutdownAndWait() {
            shutdownCount += 1
            isConnected = false
        }

        func triggerDisconnect() {
            onDisconnect?()
        }

        func triggerEvent(_ frame: CxiFrame) {
            onEvent?(frame)
        }
    }

    private enum FakeError: LocalizedError, Equatable {
        case handshake

        var errorDescription: String? { "fake handshake failed" }
    }
}
