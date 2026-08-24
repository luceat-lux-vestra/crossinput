import XCTest
@testable import App
import AndroidBridge
import Protocol
import EdgeSwitch
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


    // MARK: - Issue #62: batch admission and delivery semantics

    /// Counts completions per enqueue so callback cardinality can be asserted
    /// against the helper's request count (ADR-0011: one batch = one result).
    private final class CompletionCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func call() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    // Batch callback cardinality regression: a parked button boundary keeps
    // the queue stable while nine raw moves coalesce into ONE queued batch.
    // The rejected fan-out implementation invoked ten callbacks here.
    func testTenRawMovesCoalesceIntoOneRequestAndOneCallback() {
        let session = FakeSession()
        session.gateAllRequests = true
        let reference = SessionReference()
        reference.set(session)
        let sender = InputSender(session: reference)
        let callbacks = CompletionCounter()

        sender.enqueuePointer(PointerEvent(.button(button: 0, down: true))) { _ in }
        var polls = 0
        while session.requestsInFlight == 0 {
            usleep(5_000); polls += 1
            if polls > 2000 { XCTFail("first request never became in-flight"); return }
        }

        for _ in 0..<9 {
            sender.enqueuePointer(PointerEvent(.move(dx: 1, dy: 0))) { _ in callbacks.call() }
        }
        session.releaseGate()
        sender.waitForDrain()

        XCTAssertEqual(session.requestCount, 2, "button boundary + one merged move batch")
        XCTAssertEqual(callbacks.value, 1,
                       "nine merges must collapse into ONE acknowledgement, never nine")
        XCTAssertEqual(session.requestTypes.filter { $0 == .pointerButton }.count, 1,
                       "button appears exactly once")
        XCTAssertEqual(session.acceptedMovement.0, 9,
                       "aggregate delta of the coalesced move batch is preserved")
    }

    // End-to-end handoff accounting: duplicated accounting would over-credit
    // return-direction movement and force an early boundary return.
    func testCoalescedReturnMoveCreditsHandoffOnce() async {
        let session = FakeSession()
        session.gateAllRequests = true
        let reference = SessionReference()
        reference.set(session)
        let sender = InputSender(session: reference)
        let machine = EdgeSwitchStateMachine(returnHysteresis: 60)
        let controller = ControlHandoffController(sender: sender,
                                                  switchMachine: machine)
        let states = ResultBox<HandoffState>()
        machine.onStateChange = { states.set($0.to) }

        machine.activate()
        machine.pointerAtEdge(.right) // localActive -> edgeArmed -> remoteActive
        machine.flushCallbacks()
        XCTAssertEqual(machine.state, .remoteActive)

        controller.enqueueForTesting(PointerEvent(.move(dx: 1, dy: 0)))
        var polls = 0
        while session.requestsInFlight == 0 {
            usleep(5_000); polls += 1
            if polls > 2000 { XCTFail("request never became in-flight"); return }
        }
        for _ in 0..<9 {
            controller.enqueueForTesting(PointerEvent(.move(dx: 1, dy: 0)))
        }
        session.releaseGate()
        sender.waitForDrain()
        machine.flushCallbacks()
        // Completion handling hops through Task { @MainActor }; yield so the
        // actor drains pending delivery tasks before asserting.
        for _ in 0..<50 { await Task.yield() }

        // Pull back: the aggregated credit crosses -hysteresis exactly once.
        controller.enqueueForTesting(PointerEvent(.move(dx: -100, dy: 0)))
        sender.waitForDrain()
        machine.flushCallbacks()
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(states.get(), .localActive,
                       "return-direction movement must fire exactly one return")
    }

    // Deterministic scroll coalescing: the first transport request is held by
    // the gate so queue state is known before adjacent scrolls are admitted.
    func testAdjacentScrollsCoalesceWhileFirstRequestIsGated() {
        let session = FakeSession()
        session.gateAllRequests = true
        let reference = SessionReference()
        reference.set(session)
        let sender = InputSender(session: reference)

        sender.enqueuePointer(PointerEvent(.scroll(horizontal: 2.5, vertical: 3))) { _ in }
        var polls = 0
        while session.requestsInFlight == 0 {
            usleep(5_000); polls += 1
            if polls > 2000 { XCTFail("request never became in-flight"); return }
        }

        sender.enqueuePointer(PointerEvent(.scroll(horizontal: 1.5, vertical: -1))) { _ in }
        sender.enqueuePointer(PointerEvent(.scroll(horizontal: -1, vertical: 4))) { _ in }
        session.releaseGate()
        sender.waitForDrain()

        // Gated head (2.5, 3) is in flight; the next two scrolls form a
        // second batch and merge together: requests = head + merged batch.
        XCTAssertEqual(session.requestTypes.count, 2,
                       "gated head batch plus one merged scroll batch")
        XCTAssertEqual(session.acceptedScroll.0, 2.5 + 1.5 - 1, accuracy: 0.0001,
                       "horizontal accumulates across both batches")
        XCTAssertEqual(session.acceptedScroll.1, 3.0 + 3.0, accuracy: 0.0001,
                       "vertical accumulates across both batches")
    }

    func testScrollMatrixAccumulatesWithTolerance() {
        let cases: [(Float, Float, Float, Float)] = [
            (2, 0, 3, 0),      // (+h, 0) + (+h, 0)
            (-2, 0, -3, 0),    // (-h, 0) + (-h, 0)
            (2, 0, -5, 0),     // (+h, 0) + (-h, 0)
            (0, 2, 0, 3),      // (0, +v) + (0, +v)
            (0, -2, 0, -3),    // (0, -v) + (0, -v)
            (0, 2, 0, -5),     // (0, +v) + (0, -v)
            (2, 3, -5, -7),    // (+h, +v) + (-h, -v)
        ]
        for (h1, v1, h2, v2) in cases {
            let session = FakeSession()
            let reference = SessionReference()
            reference.set(session)
            let sender = InputSender(session: reference)

            sender.enqueuePointer(PointerEvent(.scroll(horizontal: h1, vertical: v1))) { _ in }
            sender.enqueuePointer(PointerEvent(.scroll(horizontal: h2, vertical: v2))) { _ in }
            sender.waitForDrain()

            XCTAssertEqual(session.requestCount, 1, "\(h1),\(v1)+\(h2),\(v2)")
            XCTAssertEqual(session.acceptedScroll.0, h1 + h2, accuracy: 0.0001)
            XCTAssertEqual(session.acceptedScroll.1, v1 + v2, accuracy: 0.0001)
        }
    }

    func testOrderingBoundariesRemainSeparateRequests() {
        // scroll -> button -> scroll
        assertOrder([.scroll(horizontal: 0, vertical: 1),
                     .button(button: 0, down: true),
                     .scroll(horizontal: 0, vertical: 2)],
                    expected: [.pointerScroll, .pointerButton, .pointerScroll])
        // scroll -> move -> scroll
        assertOrder([.scroll(horizontal: 0, vertical: 1),
                     .move(dx: 5, dy: 5),
                     .scroll(horizontal: 0, vertical: 2)],
                    expected: [.pointerScroll, .pointerMoveRel, .pointerScroll])
        // move -> scroll -> move
        assertOrder([.move(dx: 1, dy: 0),
                     .scroll(horizontal: 0, vertical: 1),
                     .move(dx: 2, dy: 0)],
                    expected: [.pointerMoveRel, .pointerScroll, .pointerMoveRel])
    }

    func testButtonDownScrollBurstButtonUpStaysOrderedAndLossless() {
        let session = FakeSession(delay: 50_000_000)
        let reference = SessionReference()
        reference.set(session)
        let sender = InputSender(session: reference,
                                 maxPendingPointerItems: 2,
                                 pointerRequestTimeout: 1)

        sender.enqueuePointer(PointerEvent(.button(button: 0, down: true))) { _ in }
        for i in 0..<200 {
            sender.enqueuePointer(PointerEvent(.scroll(horizontal: Float(i % 3) - 1,
                                                        vertical: 1))) { _ in }
        }
        sender.enqueuePointer(PointerEvent(.button(button: 0, down: false))) { _ in }
        sender.waitForDrain()

        XCTAssertEqual(session.pointerButtonEvents.count, 2,
                       "exactly one down and one up request reach the helper")
        XCTAssertEqual(session.pointerButtonEvents.map(\.1), [true, false],
                       "button down/up must both reach the helper exactly once, in order")
        let buttonIndices = session.requestTypes.enumerated().compactMap {
            $0.element == .pointerButton ? $0.offset : nil
        }
        XCTAssertEqual(buttonIndices.first, 0, "button-down is the first request")
        XCTAssertEqual(buttonIndices.last, session.requestTypes.count - 1,
                       "button-up is the final request")
    }

    private func assertOrder(_ kinds: [PointerEvent.Kind],
                             expected: [MessageType],
                             file: StaticString = #filePath,
                             line: UInt = #line) {
        let session = FakeSession()
        let reference = SessionReference()
        reference.set(session)
        let sender = InputSender(session: reference)
        for kind in kinds {
            sender.enqueuePointer(PointerEvent(kind)) { _ in }
        }
        sender.waitForDrain()
        XCTAssertEqual(session.requestTypes, expected, file: file, line: line)
    }

    func testMoveSaturationShedsLocallyWithoutDeliveryResult() {
        let session = FakeSession()
        session.gateAllRequests = true
        let reference = SessionReference()
        reference.set(session)
        let sender = InputSender(session: reference,
                                 maxPendingPointerItems: 1,
                                 pointerRequestTimeout: 1)

        sender.enqueuePointer(PointerEvent(.move(dx: 9, dy: 9))) { _ in }
        var polls = 0
        while session.requestsInFlight == 0 {
            usleep(5_000); polls += 1
            if polls > 2000 { XCTFail("request never became in-flight"); return }
        }

        // Fill capacity 1 with a scroll boundary so incoming moves cannot
        // merge and must hit the saturation policy.
        sender.enqueuePointer(PointerEvent(.scroll(horizontal: 0, vertical: 1))) { _ in }
        let shedCallbacks = CompletionCounter()
        for _ in 0..<20 {
            sender.enqueuePointer(PointerEvent(.move(dx: 1, dy: 1))) { _ in shedCallbacks.call() }
        }
        session.releaseGate()
        sender.waitForDrain()

        XCTAssertEqual(shedCallbacks.value, 0,
                       "shed additive events were never admitted: no delivery result exists")
    }

    func testScrollSaturationShedsLocallyWithoutDeliveryResult() {
        let session = FakeSession()
        session.gateAllRequests = true
        let reference = SessionReference()
        reference.set(session)
        let sender = InputSender(session: reference,
                                 maxPendingPointerItems: 1,
                                 pointerRequestTimeout: 1)

        sender.enqueuePointer(PointerEvent(.scroll(horizontal: 0, vertical: 1))) { _ in }
        var polls = 0
        while session.requestsInFlight == 0 {
            usleep(5_000); polls += 1
            if polls > 2000 { XCTFail("request never became in-flight"); return }
        }

        sender.enqueuePointer(PointerEvent(.move(dx: 1, dy: 1))) { _ in }
        let shedCallbacks = CompletionCounter()
        for _ in 0..<20 {
            sender.enqueuePointer(PointerEvent(.scroll(horizontal: 0, vertical: 2))) { _ in shedCallbacks.call() }
        }
        session.releaseGate()
        sender.waitForDrain()

        XCTAssertEqual(shedCallbacks.value, 0,
                       "local saturation must never produce a remote-failure signal")
    }

    func testButtonOverflowAtSaturationStillFailsClosed() {
        let session = FakeSession()
        session.gateAllRequests = true
        let reference = SessionReference()
        reference.set(session)
        let sender = InputSender(session: reference,
                                 maxPendingPointerItems: 1,
                                 pointerRequestTimeout: 1)

        sender.enqueuePointer(PointerEvent(.button(button: 0, down: true))) { _ in }
        var polls = 0
        while session.requestsInFlight == 0 {
            usleep(5_000); polls += 1
            if polls > 2000 { XCTFail("request never became in-flight"); return }
        }
        sender.enqueuePointer(PointerEvent(.scroll(horizontal: 0, vertical: 1))) { _ in }

        let overflowResult = ResultBox<PointerDeliveryResult>()
        let done = DispatchSemaphore(value: 0)
        sender.enqueuePointer(PointerEvent(.button(button: 0, down: false))) { result in
            overflowResult.set(result)
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(overflowResult.get(), .failed,
                       "a button that cannot be enqueued losslessly keeps the fail-safe signal")
        session.releaseGate()
        sender.waitForDrain()
    }

    func testGenuineRequestFailureStillFails() {
        let session = FailingSession()
        let reference = SessionReference()
        reference.set(session)
        let sender = InputSender(session: reference, pointerRequestTimeout: 1)
        let result = ResultBox<PointerDeliveryResult>()
        let done = DispatchSemaphore(value: 0)

        sender.enqueuePointer(PointerEvent(.scroll(horizontal: 0, vertical: 1))) {
            result.set($0)
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(result.get(), .failed,
                       "genuine transport/helper failure keeps the fail-safe signal")
    }

    func testUnexpectedResponseTypeFails() {
        let session = FakeSession(response: CxiFrame(type: .keyEvent,
                                                      requestId: 1,
                                                      payload: Data([0])))
        let reference = SessionReference()
        reference.set(session)
        let sender = InputSender(session: reference, pointerRequestTimeout: 1)
        let result = ResultBox<PointerDeliveryResult>()
        let done = DispatchSemaphore(value: 0)

        sender.enqueuePointer(PointerEvent(.scroll(horizontal: 0, vertical: 1))) {
            result.set($0)
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(result.get(), .failed)
    }

    func testHelperReportedFailureStillFails() {
        let session = FakeSession(response: CxiFrame(
            type: .pointerResult, requestId: 1,
            payload: Messages.pointerResult(status: .failed)))
        let reference = SessionReference()
        reference.set(session)
        let sender = InputSender(session: reference, pointerRequestTimeout: 1)
        let result = ResultBox<PointerDeliveryResult>()
        let done = DispatchSemaphore(value: 0)

        sender.enqueuePointer(PointerEvent(.scroll(horizontal: 0, vertical: 1))) {
            result.set($0)
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(result.get(), .failed)
    }

    func testPartialMovementBehaviorIsPreservedAfterCoalescing() {
        let session = FakeSession(response: CxiFrame(
            type: .pointerResult,
            requestId: 1,
            payload: Messages.pointerResult(status: .partiallyDelivered,
                                             deliveredDx: 127,
                                             deliveredDy: 0)))
        session.gateAllRequests = true
        let reference = SessionReference()
        reference.set(session)
        let sender = InputSender(session: reference)
        let result = ResultBox<PointerDeliveryResult>()
        let done = DispatchSemaphore(value: 0)

        // Park a button boundary in flight so the move burst forms one
        // QUEUED batch that merges fully before delivery.
        sender.enqueuePointer(PointerEvent(.button(button: 0, down: true))) { _ in }
        var polls = 0
        while session.requestsInFlight == 0 {
            usleep(5_000); polls += 1
            if polls > 2000 { XCTFail("request never became in-flight"); return }
        }
        // The FIRST enqueue owns the batch's single acknowledgement; later
        // merges keep that original completion by design (ADR-0011).
        sender.enqueuePointer(PointerEvent(.move(dx: 150, dy: 0))) {
            result.set($0)
            done.signal()
        }
        sender.enqueuePointer(PointerEvent(.move(dx: 150, dy: 0))) { _ in }
        session.releaseGate()
        sender.waitForDrain()
        XCTAssertEqual(done.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(result.get(), .partiallyDeliveredMovement(requestedDx: 300, requestedDy: 0,
                                                                  deliveredDx: 127, deliveredDy: 0))
    }

    func testCoalescedBatchOnReplacedSessionIsCancelledAndNeverDelivered() {
        let oldSession = FakeSession()
        oldSession.gateAllRequests = true
        let newSession = FakeSession()
        let reference = SessionReference()
        reference.set(oldSession)
        let sender = InputSender(session: reference, pointerRequestTimeout: 1)

        sender.enqueuePointer(PointerEvent(.button(button: 0, down: true))) { _ in }
        var polls = 0
        while oldSession.requestsInFlight == 0 {
            usleep(5_000); polls += 1
            if polls > 2000 { XCTFail("request never became in-flight"); return }
        }
        sender.enqueuePointer(PointerEvent(.scroll(horizontal: 4, vertical: 4))) { _ in }
        sender.enqueuePointer(PointerEvent(.scroll(horizontal: 6, vertical: 6))) { _ in }

        reference.set(newSession)
        oldSession.releaseGate()
        sender.waitForDrain()

        XCTAssertEqual(newSession.requestCount, 0,
                       "stale coalesced work must not reach the replacement session")
        XCTAssertEqual(newSession.acceptedScroll.0, 0, accuracy: 0.0001)
    }

    func testCancelledInFlightBatchNeverCreditsMovement() async {
        let session = FakeSession()
        session.gateAllRequests = true
        let reference = SessionReference()
        reference.set(session)
        let sender = InputSender(session: reference, pointerRequestTimeout: 5)
        let machine = EdgeSwitchStateMachine(returnHysteresis: 60)
        let controller = ControlHandoffController(sender: sender,
                                                  switchMachine: machine)
        machine.onStateChange = { _ in }

        machine.activate()
        machine.pointerAtEdge(.right)
        machine.flushCallbacks()
        XCTAssertEqual(machine.state, .remoteActive)

        controller.enqueueForTesting(PointerEvent(.move(dx: 40, dy: 40)))
        var polls = 0
        while session.requestsInFlight == 0 {
            usleep(5_000); polls += 1
            if polls > 2000 { XCTFail("request never became in-flight"); return }
        }

        sender.cancelPendingPointerEvents()
        session.releaseGate()
        sender.waitForDrain()
        machine.flushCallbacks()
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(machine.state, .remoteActive,
                       "cancelled stale in-flight movement must not update handoff position")
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
        private(set) var acceptedScroll: (Float, Float) = (0, 0)
        private(set) var requestTypes: [MessageType] = []
        private(set) var pointerButtonEvents: [(UInt32, Bool)] = []
        private(set) var sentPointerButtonEvents: [(UInt32, Bool)] = []
        private(set) var sentFrames: [CxiFrame] = []
        private(set) var sendCount = 0
        let requestStarted = DispatchSemaphore(value: 0)
        let sendStarted = DispatchSemaphore(value: 0)
        private let inFlightLock = NSLock()
        private var inFlightStorage = 0
        /// Requests currently inside the fake transport. Observing >0 proves
        /// a request is in flight regardless of where it is blocked.
        var requestsInFlight: Int { inFlightLock.withLock { inFlightStorage } }

        /// Test gate: when true, every request blocks inside the fake until
        /// releaseGate() is called. Deterministic pending-queue control.
        var gateAllRequests = false
        private let gateLock = NSLock()
        private var gateOpen = false

        func releaseGate() {
            gateLock.withLock { gateOpen = true }
        }

        init(response: CxiFrame? = nil, delay: UInt64 = 0, sendDelay: UInt64 = 0) {
            self.response = response
            self.delay = delay
            self.sendDelay = sendDelay
        }

        func connect() async throws {}

        func request(_ type: MessageType, payload: Data, timeout: TimeInterval?) async throws -> CxiFrame {
            inFlightLock.withLock { inFlightStorage += 1 }
            defer { inFlightLock.withLock { inFlightStorage -= 1 } }
            if gateAllRequests {
                // Block after entering, before recording, so the test can
                // observe a request that is provably in flight.
                while !gateLock.withLock({ gateOpen }) {
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
            }
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
                if type == .pointerScroll, payload.count >= 8 {
                    let h = payload.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
                    let v = payload.withUnsafeBytes {
                        $0.loadUnaligned(fromByteOffset: 4, as: Float.self)
                    }
                    acceptedScroll.0 += h
                    acceptedScroll.1 += v
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

    /// Connection whose every request throws — models genuine transport loss.
    private final class FailingSession: SessionConnection, @unchecked Sendable {
        let serial = "fake-failing"
        var isConnected = true
        var onEvent: (@Sendable (CxiFrame) -> Void)?
        var onDisconnect: (@Sendable () -> Void)?

        func connect() async throws {}
        func request(_ type: MessageType, payload: Data, timeout: TimeInterval?) async throws -> CxiFrame {
            throw ConnectionError.timeout("fake transport failure")
        }
        func send(_ frame: CxiFrame) throws {}
        func shutdownAndWait() { isConnected = false }
    }
}
