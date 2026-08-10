import XCTest
@testable import App
import AndroidBridge
import Protocol
import InputCapture

@MainActor
final class InputSenderTests: XCTestCase {
    func testMovementUsesHelperAcceptedDelta() {
        let session = FakeSession(response: CxiFrame(
            type: .pointerResult,
            requestId: 1,
            payload: Messages.pointerResult(status: .delivered,
                                             deliveredDx: 3,
                                             deliveredDy: 4)))
        let reference = SessionReference()
        reference.set(session)
        let sender = InputSender(session: reference)
        let result = ResultBox<PointerDeliveryResult>()
        let done = DispatchSemaphore(value: 0)

        sender.enqueuePointer(PointerEvent(.move(dx: 10, dy: 20))) {
            result.set($0)
            done.signal()
        }

        XCTAssertEqual(done.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(result.get(), .deliveredMovement(dx: 3, dy: 4))
    }

    func testPartialMovementIsReportedWithoutRetry() {
        let session = FakeSession(response: CxiFrame(
            type: .pointerResult,
            requestId: 1,
            payload: Messages.pointerResult(status: .partiallyDelivered,
                                             deliveredDx: 127,
                                             deliveredDy: 0)))
        let reference = SessionReference()
        reference.set(session)
        let sender = InputSender(session: reference)
        let result = ResultBox<PointerDeliveryResult>()
        let done = DispatchSemaphore(value: 0)

        sender.enqueuePointer(PointerEvent(.move(dx: 300, dy: 0))) {
            result.set($0)
            done.signal()
        }

        XCTAssertEqual(done.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(result.get(), .partiallyDeliveredMovement(dx: 127, dy: 0))
        XCTAssertEqual(session.requestCount, 1)
    }

    private final class ResultBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value?

        func set(_ value: Value) { lock.withLock { self.value = value } }
        func get() -> Value? { lock.withLock { value } }
    }

    private final class FakeSession: SessionConnection, @unchecked Sendable {
        let serial = "fake"
        let response: CxiFrame
        var requestCount = 0
        var isConnected = true
        var onEvent: (@Sendable (CxiFrame) -> Void)?
        var onDisconnect: (@Sendable () -> Void)?

        init(response: CxiFrame) {
            self.response = response
        }

        func connect() async throws {}

        func request(_ type: MessageType, payload: Data, timeout: TimeInterval?) async throws -> CxiFrame {
            requestCount += 1
            return response
        }

        func send(_ frame: CxiFrame) throws {}
        func shutdownAndWait() { isConnected = false }
    }
}
