import XCTest
@testable import App
@testable import Delivery
import Protocol
import InputCapture
import AndroidBridge

/// Review round 5 item 7: mutation-resistant coverage for the telemetry
/// ownership split.
///
/// Invariants pinned here:
/// - Transport failures (timeout / streamClosed) produce a `.failed`
///   PointerDeliveryResult but ZERO semantic observations from InputSender —
///   RemoteSession owns transport outcomes, so one transport failure must
///   never appear twice in production diagnostics.
/// - Semantic outcomes emit exactly one observation each:
///   malformed payload → .malformedResponse; wrong response type →
///   .unexpectedResponse; helper status failed → .helperReportedFailure;
///   movement partial → .partialDelivery (product fail-safe target — it must
///   never be invisible in diagnostics).
@MainActor
final class TelemetryOwnershipTests: XCTestCase {
    /// Minimal session fake: scripted response or thrown error per request.
    private final class ScriptedSession: SessionConnection, @unchecked Sendable {
        enum Behavior {
            case respond(CxiFrame)
            case fail(Error)
        }

        let serial = "scripted"
        var isConnected = true
        var onEvent: (@Sendable (CxiFrame) -> Void)?
        var onDisconnect: (@Sendable () -> Void)?
        let lock = NSLock()
        private var _behavior: Behavior

        init(behavior: Behavior) {
            _behavior = behavior
        }

        func request(_ type: MessageType, payload: Data,
                     timeout: TimeInterval?) async throws -> CxiFrame {
            let behavior: Behavior = lock.withLock { _behavior }
            switch behavior {
            case .respond(let frame):
                return frame
            case .fail(let error):
                throw error
            }
        }

        func send(_ frame: CxiFrame) throws {}
        func connect() async throws {}
        func shutdownAndWait() { isConnected = false }
    }

    private final class ObservationBox: @unchecked Sendable {
        let lock = NSLock()
        var observations: [RequestObservation] = []
        var count: Int { lock.withLock { observations.count } }
        func append(_ o: RequestObservation) {
            lock.withLock { observations.append(o) }
        }
        func firstOutcome() -> RequestObservation.Outcome? {
            lock.withLock { observations.first?.outcome }
        }
    }

    /// Runs one scroll batch through the real InputSender against the
    /// scripted session and returns (delivery result, semantic observations).
    private func runScroll(
        behavior: ScriptedSession.Behavior,
        timeout: TimeInterval = 2
    ) async -> (PointerDeliveryResult?, ObservationBox) {
        let session = ScriptedSession(behavior: behavior)
        let reference = SessionReference()
        reference.set(session)
        let sender = InputSender(session: reference,
                                 pointerRequestTimeout: timeout)
        let box = ObservationBox()
        sender.onDeliveryObservation = { box.append($0) }

        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = ResultBox()
        sender.enqueuePointer(PointerEvent(.scroll(horizontal: 1, vertical: 1))) { result in
            resultBox.store(result)
            semaphore.signal()
        }
        XCTAssertEqual(semaphore.wait(timeout: .now() + 5), .success,
                       "batch completion never arrived")
        sender.waitForDrain()
        return (resultBox.load(), box)
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _result: PointerDeliveryResult?
        func store(_ r: PointerDeliveryResult) {
            lock.withLock { _result = r }
        }
        func load() -> PointerDeliveryResult? {
            lock.withLock { _result }
        }
    }

    private static func pointerResultData(status: PointerDeliveryStatus) -> Data {
        Data([status.rawValue]) + Data([0,0,0,0]) + Data([0,0,0,0])
    }

    // MARK: - A. Transport failures are owned by RemoteSession

    func testTransportTimeoutEmitsNoSemanticObservation() async {
        let (result, box) = await runScroll(
            behavior: .fail(ConnectionError.timeout("no response")))
        guard case .failed = result else {
            XCTFail("expected .failed, got \(String(describing: result))")
            return
        }
        XCTAssertEqual(box.count, 0,
                       "transport timeout is RemoteSession-owned; InputSender must not re-emit")
    }

    func testStreamClosedEmitsNoSemanticObservation() async {
        let (result, box) = await runScroll(
            behavior: .fail(ConnectionError.streamClosed))
        guard case .failed = result else {
            XCTFail("expected .failed, got \(String(describing: result))")
            return
        }
        XCTAssertEqual(box.count, 0,
                       "stream-closed is RemoteSession-owned; no duplicate diagnostic")
    }

    // MARK: - B. Malformed POINTER_RESULT payload

    func testMalformedPayloadEmitsExactlyOneMalformedResponse() async {
        let frame = CxiFrame(type: .pointerResult, requestId: 1,
                             payload: Data([0x7F])) // invalid status byte
        let (result, box) = await runScroll(behavior: .respond(frame))
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(box.count, 1)
        if case .malformedResponse(let kind)? = box.firstOutcome() {
            XCTAssertEqual(kind, .pointerScroll)
        } else {
            XCTFail("expected malformedResponse, got \(String(describing: box.firstOutcome()))")
        }
    }

    // MARK: - C. Wrong response type

    func testWrongResponseTypeEmitsExactlyOneUnexpectedResponse() async {
        let frame = CxiFrame(type: .pong, requestId: 1)
        let (result, box) = await runScroll(behavior: .respond(frame))
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(box.count, 1)
        if case .unexpectedResponse(let kind)? = box.firstOutcome() {
            XCTAssertEqual(kind, .pointerScroll)
        } else {
            XCTFail("expected unexpectedResponse, got \(String(describing: box.firstOutcome()))")
        }
    }

    // MARK: - D. Helper-reported failure

    func testHelperFailureEmitsExactlyOneHelperReportedFailure() async {
        let frame = CxiFrame(type: .pointerResult, requestId: 1,
                             payload: Self.pointerResultData(status: .failed))
        let (result, box) = await runScroll(behavior: .respond(frame))
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(box.count, 1)
        if case .helperReportedFailure(let kind)? = box.firstOutcome() {
            XCTAssertEqual(kind, .pointerScroll)
        } else {
            XCTFail("expected helperReportedFailure, got \(String(describing: box.firstOutcome()))")
        }
    }

    // MARK: - E. Movement partial is visible

    func testPartialMovementEmitsExactlyOnePartialDeliveryAndStaysFailedSafe() async {
        // A MOVE with partial delivery: product treats this as force-return.
        let session = ScriptedSession(behavior: .respond(CxiFrame(
            type: .pointerResult, requestId: 1,
            payload: Self.pointerResultData(status: .partiallyDelivered))))
        let reference = SessionReference()
        reference.set(session)
        let sender = InputSender(session: reference, pointerRequestTimeout: 2)
        let box = ObservationBox()
        sender.onDeliveryObservation = { box.append($0) }

        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = ResultBox()
        sender.enqueuePointer(PointerEvent(.move(dx: 10, dy: 10))) { result in
            resultBox.store(result)
            semaphore.signal()
        }
        XCTAssertEqual(semaphore.wait(timeout: .now() + 5), .success)

        let result = resultBox.load()
        guard case .partiallyDeliveredMovement = result else {
            XCTFail("expected partiallyDeliveredMovement, got \(String(describing: result))")
            return
        }
        XCTAssertEqual(box.count, 1,
                       "a product fail-safe outcome must never be an invisible diagnostic")
        if case .partialDelivery(let kind)? = box.firstOutcome() {
            XCTAssertEqual(kind, .pointerMoveRel)
        } else {
            XCTFail("expected partialDelivery, got \(String(describing: box.firstOutcome()))")
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
