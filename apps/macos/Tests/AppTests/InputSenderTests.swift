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

    func testHighFrequencyMovesAreCoalescedAndBounded() {
        let session = FakeSession(delay: 100_000_000)
        let reference = SessionReference()
        reference.set(session)
        let sender = InputSender(session: reference,
                                 maxPendingPointerItems: 1,
                                 pointerRequestTimeout: 1)

        for _ in 0..<100 {
            sender.enqueuePointer(PointerEvent(.move(dx: 1, dy: 2))) { _ in }
        }
        sender.waitForDrain()

        XCTAssertLessThanOrEqual(session.requestCount, 2)
        XCTAssertEqual(session.acceptedMovement.0, 100)
        XCTAssertEqual(session.acceptedMovement.1, 200)
    }

    func testButtonAndScrollRemainOrderedAroundCoalescedMoves() {
        let session = FakeSession()
        let reference = SessionReference()
        reference.set(session)
        let sender = InputSender(session: reference)

        sender.enqueuePointer(PointerEvent(.move(dx: 1, dy: 0))) { _ in }
        sender.enqueuePointer(PointerEvent(.button(button: 0, down: true))) { _ in }
        sender.enqueuePointer(PointerEvent(.move(dx: 2, dy: 0))) { _ in }
        sender.enqueuePointer(PointerEvent(.scroll(horizontal: 0, vertical: 1))) { _ in }
        sender.waitForDrain()

        XCTAssertEqual(session.requestTypes, [.pointerMoveRel, .pointerButton,
                                               .pointerMoveRel, .pointerScroll])
    }

    func testKeyboardDeliveryDoesNotWaitForStalledPointerRequest() {
        let session = FakeSession(delay: 200_000_000)
        let reference = SessionReference()
        reference.set(session)
        let sender = InputSender(session: reference, pointerRequestTimeout: 1)

        sender.enqueuePointer(PointerEvent(.move(dx: 1, dy: 0))) { _ in }
        sender.enqueueKey(CapturedKeyEvent(keyCode: 29, metaState: 0, action: 1, repeatCount: 0))

        Thread.sleep(forTimeInterval: 0.03)
        XCTAssertEqual(session.sendCount, 1)
        sender.waitForDrain()
    }

    private final class ResultBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value?

        func set(_ value: Value) { lock.withLock { self.value = value } }
        func get() -> Value? { lock.withLock { value } }
    }

    private final class FakeSession: SessionConnection, @unchecked Sendable {
        let serial = "fake"
        let response: CxiFrame?
        let delay: UInt64
        private let lock = NSLock()
        var requestCount = 0
        var isConnected = true
        var onEvent: (@Sendable (CxiFrame) -> Void)?
        var onDisconnect: (@Sendable () -> Void)?
        private(set) var acceptedMovement: (Int32, Int32) = (0, 0)
        private(set) var requestTypes: [MessageType] = []
        private(set) var sendCount = 0

        init(response: CxiFrame? = nil, delay: UInt64 = 0) {
            self.response = response
            self.delay = delay
        }

        func connect() async throws {}

        func request(_ type: MessageType, payload: Data, timeout: TimeInterval?) async throws -> CxiFrame {
            lock.withLock {
                requestCount += 1
                requestTypes.append(type)
            }
            if delay > 0 {
                if let timeout, Double(delay) / 1_000_000_000 > timeout {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw ConnectionError.timeout("fake pointer request")
                }
                try await Task.sleep(nanoseconds: delay)
            }
            if let response { return response }
            if type == .pointerMoveRel, payload.count >= 8 {
                let dx = payload.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
                let dy = payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int32.self) }
                lock.withLock {
                    acceptedMovement.0 += dx
                    acceptedMovement.1 += dy
                }
                return CxiFrame(type: .pointerResult, requestId: 1,
                                payload: Messages.pointerResult(status: .delivered,
                                                                 deliveredDx: dx,
                                                                 deliveredDy: dy))
            }
            return CxiFrame(type: .pointerResult, requestId: 1,
                            payload: Messages.pointerResult(status: .delivered))
        }

        func send(_ frame: CxiFrame) throws { lock.withLock { sendCount += 1 } }
        func shutdownAndWait() { isConnected = false }
    }
}
