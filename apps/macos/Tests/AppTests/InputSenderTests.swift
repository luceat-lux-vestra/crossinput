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
        XCTAssertEqual(result.get(), .deliveredMovement(requestedDx: 10, requestedDy: 20,
                                                        deliveredDx: 3, deliveredDy: 4))
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
        XCTAssertEqual(result.get(), .partiallyDeliveredMovement(requestedDx: 300, requestedDy: 0,
                                                                 deliveredDx: 127, deliveredDy: 0))
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

    func testQueuedPointerOnReplacedSessionIsNotSentToNewSession() {
        let oldSession = FakeSession(delay: 200_000_000)
        let newSession = FakeSession()
        let reference = SessionReference()
        reference.set(oldSession)
        let sender = InputSender(session: reference, pointerRequestTimeout: 1)
        let firstResult = ResultBox<PointerDeliveryResult>()
        let queuedResult = ResultBox<PointerDeliveryResult>()
        let firstDone = DispatchSemaphore(value: 0)
        let queuedDone = DispatchSemaphore(value: 0)

        sender.enqueuePointer(PointerEvent(.move(dx: 10, dy: 0))) {
            firstResult.set($0)
            firstDone.signal()
        }
        XCTAssertEqual(oldSession.requestStarted.wait(timeout: .now() + 1), .success)

        sender.enqueuePointer(PointerEvent(.move(dx: 20, dy: 0))) {
            queuedResult.set($0)
            queuedDone.signal()
        }
        reference.set(newSession)
        sender.waitForDrain()

        XCTAssertEqual(firstDone.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(queuedDone.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(firstResult.get(), .cancelled)
        XCTAssertEqual(queuedResult.get(), .cancelled)
        XCTAssertEqual(newSession.requestCount, 0)
    }

    func testQueuedKeyboardOnReplacedSessionIsDropped() {
        let oldSession = FakeSession(sendDelay: 200_000_000)
        let newSession = FakeSession()
        let reference = SessionReference()
        reference.set(oldSession)
        let sender = InputSender(session: reference)
        let key = CapturedKeyEvent(keyCode: 29, metaState: 0, action: 1, repeatCount: 0)

        sender.enqueueKey(key)
        XCTAssertEqual(oldSession.sendStarted.wait(timeout: .now() + 1), .success)
        sender.enqueueKey(key)
        reference.set(newSession)
        sender.waitForDrain()

        XCTAssertEqual(oldSession.sendCount, 1)
        XCTAssertEqual(newSession.sendCount, 0)
    }

    func testExternalControlResetReleasesAcceptedPointerButtons() {
        let session = FakeSession()
        let reference = SessionReference()
        reference.set(session)
        let sender = InputSender(session: reference)
        let delivered = DispatchSemaphore(value: 0)
        let result = ResultBox<PointerDeliveryResult>()

        sender.enqueuePointer(PointerEvent(.button(button: 0, down: true))) {
            result.set($0)
            delivered.signal()
        }
        XCTAssertEqual(delivered.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(result.get(), .delivered)

        sender.resetCapturedInputState()
        sender.waitForDrain()

        XCTAssertEqual(session.pointerButtonEvents.map(\.0), [0])
        XCTAssertEqual(session.pointerButtonEvents.map(\.1), [true])
        XCTAssertEqual(session.sentPointerButtonEvents.map(\.0), [0])
        XCTAssertEqual(session.sentPointerButtonEvents.map(\.1), [false])
        XCTAssertEqual(session.sentFrames.last?.requestId, 0)
    }

    func testExternalControlResetQueuesCleanupWithoutBlockingLocalReturn() {
        let session = FakeSession(sendDelay: 100_000_000)
        let reference = SessionReference()
        reference.set(session)
        let sender = InputSender(session: reference)

        sender.enqueueKey(CapturedKeyEvent(keyCode: 29, metaState: 0,
                                           action: 1, repeatCount: 0))
        XCTAssertEqual(session.sendStarted.wait(timeout: .now() + 1), .success)

        let started = CFAbsoluteTimeGetCurrent()
        sender.resetCapturedInputState()
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        sender.waitForDrain()

        XCTAssertLessThan(elapsed, 0.05)
        XCTAssertEqual(session.sendCount, 1)
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
        let sendDelay: UInt64
        private let lock = NSLock()
        var requestCount = 0
        var isConnected = true
        var onEvent: (@Sendable (CxiFrame) -> Void)?
        var onDisconnect: (@Sendable () -> Void)?
        private(set) var acceptedMovement: (Int32, Int32) = (0, 0)
        private(set) var requestTypes: [MessageType] = []
        private(set) var pointerButtonEvents: [(UInt32, Bool)] = []
        private(set) var sentPointerButtonEvents: [(UInt32, Bool)] = []
        private(set) var sentFrames: [CxiFrame] = []
        private(set) var sendCount = 0
        let requestStarted = DispatchSemaphore(value: 0)
        let sendStarted = DispatchSemaphore(value: 0)

        init(response: CxiFrame? = nil, delay: UInt64 = 0, sendDelay: UInt64 = 0) {
            self.response = response
            self.delay = delay
            self.sendDelay = sendDelay
        }

        func connect() async throws {}

        func request(_ type: MessageType, payload: Data, timeout: TimeInterval?) async throws -> CxiFrame {
            requestStarted.signal()
            lock.withLock {
                requestCount += 1
                requestTypes.append(type)
                if type == .pointerButton, payload.count >= 5 {
                    let button = payload.withUnsafeBytes { raw in
                        UInt32(littleEndian: raw.loadUnaligned(as: UInt32.self))
                    }
                    pointerButtonEvents.append((button, payload[4] != 0))
                }
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

        func send(_ frame: CxiFrame) throws {
            sendStarted.signal()
            lock.withLock {
                sendCount += 1
                sentFrames.append(frame)
                if frame.type == .pointerButton, frame.payload.count >= 5 {
                    let button = frame.payload.withUnsafeBytes { raw in
                        UInt32(littleEndian: raw.loadUnaligned(as: UInt32.self))
                    }
                    sentPointerButtonEvents.append((button, frame.payload[4] != 0))
                }
            }
            if sendDelay > 0 {
                Thread.sleep(forTimeInterval: Double(sendDelay) / 1_000_000_000)
            }
        }
        func shutdownAndWait() { isConnected = false }
    }
}
