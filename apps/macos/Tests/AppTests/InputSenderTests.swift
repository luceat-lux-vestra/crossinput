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

        XCTAssertEqual(session.sendStarted.wait(timeout: .now() + 1), .success)
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
    //
    // Determinism rules for every test in this section:
    // - No polling and no arbitrary sleeps. A request that must be observed
    //   in flight parks on `FakeSession.requestEntered`, which the fake
    //   signals synchronously on entry to `request`; the request stays
    //   blocked until `releaseGate()`.
    // - Queue shape is constructed deliberately: while the worker is parked
    //   inside the gated request, subsequently enqueued events sit in
    //   `pendingPointers` in exactly their enqueue order.

    /// Counts completions so callback cardinality can be asserted against
    /// the helper's request count (ADR-0011: one admitted batch yields
    /// exactly one delivery result and one handoff-accounting operation).
    private final class CompletionCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func call() { lock.withLock { count += 1 } }
        func reset() { lock.withLock { count = 0 } }
        var value: Int { lock.withLock { count } }
    }

    private struct Fixture {
        let session: FakeSession
        let reference: SessionReference
        let sender: InputSender
    }

    private func makeFixture(maxPendingPointerItems: Int = 64,
                             pointerRequestTimeout: TimeInterval = 5) -> Fixture {
        let session = FakeSession()
        session.gateAllRequests = true
        let reference = SessionReference()
        reference.set(session)
        let sender = InputSender(session: reference,
                                 maxPendingPointerItems: maxPendingPointerItems,
                                 pointerRequestTimeout: pointerRequestTimeout)
        return Fixture(session: session, reference: reference, sender: sender)
    }

    /// Waits for the worker to be provably inside the fake transport.
    private func awaitInFlight(_ session: FakeSession,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(session.requestEntered.wait(timeout: .now() + 2), .success,
                       "request never became in-flight", file: file, line: line)
    }

    /// Drains pending MainActor delivery tasks after a synchronous drain so
    /// controller-applied state changes become observable.
    private func settleMainActor() async {
        for _ in 0..<50 { await Task.yield() }
    }

    // MARK: Admission/delivery contract (ADR-0011)

    /// The admission outcome is the entire per-enqueue contract: only the
    /// enqueue that created a batch owns its single completion; coalesced,
    /// shed, and safety-rejected enqueues have no callback at any point.
    func testAdmissionOutcomesAreSeparateFromDeliveryResults() {
        let fixture = makeFixture()
        let moveOwner = ResultBox<PointerDeliveryResult>()
        let secondMoveOwner = ResultBox<PointerDeliveryResult>()
        let scrollOwner = ResultBox<PointerDeliveryResult>()
        let coalescedCallbacks = CompletionCounter()

        XCTAssertEqual(fixture.sender.enqueuePointer(
            PointerEvent(.move(dx: 1, dy: 0))) { moveOwner.set($0) },
            .acceptedAsNewBatch)
        awaitInFlight(fixture.session)

        XCTAssertEqual(fixture.sender.enqueuePointer(
            PointerEvent(.move(dx: 2, dy: 0))) { secondMoveOwner.set($0) },
            .acceptedAsNewBatch, "the in-flight head left the queue, so this move starts a new batch")
        XCTAssertEqual(fixture.sender.enqueuePointer(
            PointerEvent(.scroll(horizontal: 3, vertical: 4))) { scrollOwner.set($0) },
            .acceptedAsNewBatch, "kind change is an ordering boundary")
        XCTAssertEqual(fixture.sender.enqueuePointer(
            PointerEvent(.scroll(horizontal: 5, vertical: 6))) { _ in coalescedCallbacks.call() },
            .coalescedIntoExistingBatch)

        fixture.session.releaseGate()
        fixture.sender.waitForDrain()

        XCTAssertEqual(fixture.session.requestTypes,
                       [.pointerMoveRel, .pointerMoveRel, .pointerScroll])
        XCTAssertEqual(coalescedCallbacks.value, 0,
                       "the coalesced enqueue must never receive a delivery callback")
        XCTAssertNotNil(moveOwner.get())
        XCTAssertNotNil(secondMoveOwner.get(),
                       "each new-batch owner receives exactly one aggregate result")
        XCTAssertEqual(scrollOwner.get(), .delivered,
                       "the scroll batch owner receives exactly one aggregate result")
    }

    /// Cardinality regression for the PR #63 blocker (commit ae15c22 fanned
    /// the aggregate batch result out to every contributing completion):
    /// exactly ten raw moves are enqueued, so there must be exactly one
    /// pointerMoveRel request and exactly one movement completion carrying
    /// the aggregate. The fan-out implementation produces ten completions.
    func testTenRawMovesProduceOneMoveRequestAndOneMovementCompletion() {
        let fixture = makeFixture()
        let rawMoveCount = 10

        fixture.sender.enqueuePointer(PointerEvent(.button(button: 0, down: true))) { _ in }
        awaitInFlight(fixture.session)

        let movementCompletions = CompletionCounter()
        let aggregate = ResultBox<PointerDeliveryResult>()
        for i in 0..<rawMoveCount {
            if i == 0 {
                fixture.sender.enqueuePointer(PointerEvent(.move(dx: 1, dy: 0))) { result in
                    if case .deliveredMovement = result { movementCompletions.call() }
                    aggregate.set(result)
                }
            } else {
                fixture.sender.enqueuePointer(PointerEvent(.move(dx: 1, dy: 0))) { _ in
                    movementCompletions.call()
                }
            }
        }
        fixture.session.releaseGate()
        fixture.sender.waitForDrain()

        XCTAssertEqual(fixture.session.requestCount, 2,
                       "parked button boundary plus ONE merged movement batch")
        XCTAssertEqual(fixture.session.requestTypes.filter { $0 == .pointerMoveRel }.count, 1,
                       "ten raw moves collapse into exactly one pointerMoveRel request")
        XCTAssertEqual(movementCompletions.value, 1,
                       "one admitted batch = exactly one movement completion, never \(rawMoveCount)")
        XCTAssertEqual(aggregate.get(),
                       .deliveredMovement(requestedDx: Int32(rawMoveCount), requestedDy: 0,
                                          deliveredDx: Int32(rawMoveCount), deliveredDy: 0),
                       "the aggregate delta of all \(rawMoveCount) moves is preserved")
        XCTAssertEqual(fixture.session.acceptedMovement.0, Int32(rawMoveCount))
    }


    /// Integration proof that a coalesced aggregate movement batch is applied
    /// to handoff accounting EXACTLY ONCE through the production wiring
    /// (capture seam -> InputSender -> delivery completion ->
    /// ControlHandoffController.apply(delivery:) -> EdgeSwitchStateMachine).
    ///
    /// Mutation proof (PR #63 blocker, commit ae15c22): that implementation
    /// invoked one completion per contributing enqueue with the aggregate
    /// result. Here the coalesced (-9 * 10 = -90) return-direction batch is
    /// the FIRST movement after entering remoteActive, so the first-movement
    /// exemption (issue #37) absorbs the single credit. Under the fan-out
    /// implementation the exemption absorbs only the first of ten identical
    /// credits; the remaining nine drive the virtual position far past
    /// -hysteresis and force an immediate boundaryCrossed return. This test
    /// fails on ae15c22 and passes only when accounting happens once.
    ///
    /// Observation uses `controller.onStateChange` (the controller's outward
    /// seam) and final machine state; the production machine.onStateChange
    /// wiring installed by the controller stays connected throughout.
    func testCoalescedFirstMovementBatchIsAppliedExactlyOnce() async {
        let fixture = makeFixture()
        let machine = EdgeSwitchStateMachine(returnHysteresis: 60)
        let controller = ControlHandoffController(sender: fixture.sender,
                                                  switchMachine: machine)
        let sawLocal = CompletionCounter()
        controller.onStateChange = { state in
            if state == .local { sawLocal.call() }
        }

        machine.activate()
        machine.pointerAtEdge(.right) // localActive -> edgeArmed -> remoteActive
        machine.flushCallbacks()
        await settleMainActor()
        XCTAssertEqual(machine.state, .remoteActive)
        sawLocal.reset() // ignore the activation-time local transition

        // A parked button boundary keeps the queue stable; buttons produce no
        // movement credit and do not consume the first-movement exemption.
        controller.capture.onPointerEvent?(PointerEvent(.button(button: 0, down: true)))
        awaitInFlight(fixture.session)

        let rawMoveCount = 10
        for _ in 0..<rawMoveCount {
            controller.capture.onPointerEvent?(PointerEvent(.move(dx: -9, dy: 0)))
        }
        fixture.session.releaseGate()
        fixture.sender.waitForDrain()
        machine.flushCallbacks()
        await settleMainActor()

        XCTAssertEqual(machine.state, .remoteActive,
                       "the exempted first movement must not return control")
        XCTAssertEqual(sawLocal.value, 0,
                       "fan-out accounting would over-credit and force an early return")

        // The exemption must not make legitimate return harder: an ordinary
        // return-direction batch still crosses the hysteresis exactly once.
        controller.capture.onPointerEvent?(PointerEvent(.move(dx: -100, dy: 0)))
        fixture.sender.waitForDrain()
        machine.flushCallbacks()
        await settleMainActor()

        XCTAssertEqual(machine.state, .localActive,
                       "a deliberate return after the exempted batch must still work")
        XCTAssertEqual(sawLocal.value, 1)
    }

    // MARK: Deterministic scroll coalescing matrix (ADR-0011)

    /// Each case parks the worker on a gated button boundary so the two
    /// scrolls are provably pending adjacent in the queue before the worker
    /// can dequeue anything, then verifies the exact aggregate.
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
            let fixture = makeFixture()

            fixture.sender.enqueuePointer(PointerEvent(.button(button: 0, down: true))) { _ in }
            awaitInFlight(fixture.session)

            XCTAssertEqual(fixture.sender.enqueuePointer(
                PointerEvent(.scroll(horizontal: h1, vertical: v1))),
                .acceptedAsNewBatch)
            XCTAssertEqual(fixture.sender.enqueuePointer(
                PointerEvent(.scroll(horizontal: h2, vertical: v2))),
                .coalescedIntoExistingBatch)

            fixture.session.releaseGate()
            fixture.sender.waitForDrain()

            XCTAssertEqual(fixture.session.requestTypes, [.pointerButton, .pointerScroll],
                           "\(h1),\(v1)+\(h2),\(v2): adjacent scrolls must form one request")
            XCTAssertEqual(fixture.session.acceptedScroll.0, h1 + h2, accuracy: 0.0001)
            XCTAssertEqual(fixture.session.acceptedScroll.1, v1 + v2, accuracy: 0.0001)
        }
    }

    /// Button boundaries survive a scroll burst losslessly: the worker is
    /// parked on the gated button-down while the whole burst queues and
    /// coalesces, so ordering is proven, not hoped for.
    func testButtonDownScrollBurstButtonUpStaysOrderedAndLossless() {
        let fixture = makeFixture()

        let downCallbacks = CompletionCounter()
        fixture.sender.enqueuePointer(PointerEvent(.button(button: 0, down: true))) { result in
            if case .failed = result { downCallbacks.call() }
        }
        let burstSize = 200
        let scrollOwner = ResultBox<PointerDeliveryResult>()
        var expectedV: Float = 0
        for i in 0..<burstSize {
            let v = Float(i % 3) - 1
            expectedV += v
            if i == 0 {
                fixture.sender.enqueuePointer(
                    PointerEvent(.scroll(horizontal: Float(i % 3) - 1, vertical: v))) {
                    scrollOwner.set($0)
                }
            } else {
                fixture.sender.enqueuePointer(
                    PointerEvent(.scroll(horizontal: Float(i % 3) - 1, vertical: v))) { _ in }
            }
        }
        let upCallbacks = CompletionCounter()
        fixture.sender.enqueuePointer(PointerEvent(.button(button: 0, down: false))) { result in
            if case .failed = result { upCallbacks.call() }
        }

        fixture.session.releaseGate()
        fixture.sender.waitForDrain()

        XCTAssertEqual(fixture.session.pointerButtonEvents.count, 2,
                       "exactly one down and one up request reach the helper")
        XCTAssertEqual(fixture.session.pointerButtonEvents.map(\.1), [true, false],
                       "button down/up must both reach the helper exactly once, in order")
        let buttonIndices = fixture.session.requestTypes.enumerated().compactMap {
            $0.element == .pointerButton ? $0.offset : nil
        }
        XCTAssertEqual(buttonIndices.first, 0, "button-down is the first request")
        XCTAssertEqual(buttonIndices.last, fixture.session.requestTypes.count - 1,
                       "button-up is the final request")
        XCTAssertEqual(fixture.session.requestTypes.filter { $0 == .pointerScroll }.count, 1,
                       "the whole burst coalesces into a single scroll request")
        XCTAssertEqual(fixture.session.acceptedScroll.1, expectedV, accuracy: 0.0001,
                       "the burst aggregate is preserved end-to-end")
        XCTAssertEqual(scrollOwner.get(), .delivered)
        XCTAssertEqual(downCallbacks.value, 0, "no button safety failure")
        XCTAssertEqual(upCallbacks.value, 0, "no silent button drop")
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

    private func assertOrder(_ kinds: [PointerEvent.Kind],
                             expected: [MessageType],
                             file: StaticString = #filePath,
                             line: UInt = #line) {
        let fixture = makeFixture()
        for kind in kinds {
            fixture.sender.enqueuePointer(PointerEvent(kind)) { _ in }
        }
        fixture.session.releaseGate()
        fixture.sender.waitForDrain()
        XCTAssertEqual(fixture.session.requestTypes, expected, file: file, line: line)
    }

    // MARK: Local saturation policy (ADR-0011: shedding is not failure)

    /// Move saturation: an incompatible scroll tail fills capacity so the
    /// incoming moves cannot merge. Shedding must stay silent locally: no
    /// remote request, no delivery result, no callback, no remote-failure
    /// signal. Lost additive samples degrade fidelity only; the lost delta
    /// is NOT recovered by later events.
    func testMoveSaturationShedsLocallyWithoutDeliveryResult() {
        let fixture = makeFixture(maxPendingPointerItems: 1)

        XCTAssertEqual(fixture.sender.enqueuePointer(
            PointerEvent(.move(dx: 9, dy: 9))), .acceptedAsNewBatch)
        awaitInFlight(fixture.session)

        // Fill capacity 1 with a scroll boundary so incoming moves cannot
        // merge and must hit the saturation policy.
        XCTAssertEqual(fixture.sender.enqueuePointer(
            PointerEvent(.scroll(horizontal: 0, vertical: 1))), .acceptedAsNewBatch)
        let shedCallbacks = CompletionCounter()
        for _ in 0..<20 {
            XCTAssertEqual(fixture.sender.enqueuePointer(
                PointerEvent(.move(dx: 1, dy: 1))) { _ in shedCallbacks.call() },
                .shedLocally)
        }
        fixture.session.releaseGate()
        fixture.sender.waitForDrain()

        XCTAssertEqual(shedCallbacks.value, 0,
                       "shed additive events were never admitted: no delivery result exists")
        XCTAssertEqual(fixture.session.requestTypes, [.pointerMoveRel, .pointerScroll],
                       "shed events must not generate remote traffic")
    }

    /// Scroll saturation mirrors move saturation: local backpressure never
    /// surfaces as a remote failure.
    func testScrollSaturationShedsLocallyWithoutDeliveryResult() {
        let fixture = makeFixture(maxPendingPointerItems: 1)

        XCTAssertEqual(fixture.sender.enqueuePointer(
            PointerEvent(.scroll(horizontal: 0, vertical: 1))), .acceptedAsNewBatch)
        awaitInFlight(fixture.session)

        XCTAssertEqual(fixture.sender.enqueuePointer(
            PointerEvent(.move(dx: 1, dy: 1))), .acceptedAsNewBatch)
        let shedCallbacks = CompletionCounter()
        for _ in 0..<20 {
            XCTAssertEqual(fixture.sender.enqueuePointer(
                PointerEvent(.scroll(horizontal: 0, vertical: 2))) { _ in shedCallbacks.call() },
                .shedLocally)
        }
        fixture.session.releaseGate()
        fixture.sender.waitForDrain()

        XCTAssertEqual(shedCallbacks.value, 0,
                       "local saturation must never produce a remote-failure signal")
        XCTAssertEqual(fixture.session.requestTypes.filter { $0 == .pointerScroll }.count, 1)
    }

    /// A button transition that cannot be enqueued losslessly is a LOCAL
    /// safety decision: the completion is never invoked and no button frame
    /// is sent; the client owns the fail-safe response.
    func testButtonOverflowAtSaturationIsSafetyRejectedSilently() {
        let fixture = makeFixture(maxPendingPointerItems: 1)

        XCTAssertEqual(fixture.sender.enqueuePointer(
            PointerEvent(.button(button: 0, down: true))), .acceptedAsNewBatch)
        awaitInFlight(fixture.session)
        XCTAssertEqual(fixture.sender.enqueuePointer(
            PointerEvent(.scroll(horizontal: 0, vertical: 1))), .acceptedAsNewBatch)

        let overflowResult = ResultBox<PointerDeliveryResult>()
        let done = DispatchSemaphore(value: 0)
        let outcome = fixture.sender.enqueuePointer(
            PointerEvent(.button(button: 0, down: false))) { result in
            overflowResult.set(result)
            done.signal()
        }

        XCTAssertEqual(outcome, .safetyRejected)
        XCTAssertEqual(done.wait(timeout: .now() + 0.2), .timedOut,
                       "a safety-rejected button must not produce a delivery callback")
        XCTAssertNil(overflowResult.get(),
                     "no delivery result may exist for a rejected enqueue")
        fixture.session.releaseGate()
        fixture.sender.waitForDrain()
        XCTAssertEqual(fixture.session.pointerButtonEvents.map(\.1), [true],
                       "only the admitted button-down ever reaches the helper")
    }

    /// Controller-level effect of a button safety rejection while
    /// remoteActive: the standard fail-safe path returns control to macOS.
    /// No movement was ever delivered, so the only possible route to
    /// localActive here is the safety-rejection handler.
    func testButtonSafetyRejectionAtSaturationReturnsControlToLocal() async {
        let fixture = makeFixture(maxPendingPointerItems: 2)
        let machine = EdgeSwitchStateMachine(returnHysteresis: 60)
        let controller = ControlHandoffController(sender: fixture.sender,
                                                  switchMachine: machine)
        let sawLocal = CompletionCounter()
        controller.onStateChange = { state in
            if state == .local { sawLocal.call() }
        }

        machine.activate()
        machine.pointerAtEdge(.right)
        machine.flushCallbacks()
        await settleMainActor()
        XCTAssertEqual(machine.state, .remoteActive)
        sawLocal.reset() // ignore the activation-time local transition

        // Fill capacity 2: one scroll in flight, two scrolls queued behind it
        // (kind-compatible tails would merge, so alternate kinds).
        controller.capture.onPointerEvent?(PointerEvent(.scroll(horizontal: 1, vertical: 0)))
        awaitInFlight(fixture.session)
        controller.capture.onPointerEvent?(PointerEvent(.move(dx: 1, dy: 0)))
        controller.capture.onPointerEvent?(PointerEvent(.scroll(horizontal: 1, vertical: 0)))

        // Saturated queue: this button cannot be preserved.
        controller.capture.onPointerEvent?(PointerEvent(.button(button: 0, down: true)))
        machine.flushCallbacks()
        await settleMainActor()

        XCTAssertEqual(machine.state, .localActive,
                       "an unpreservable button transition must trip the fail-safe return")
        XCTAssertEqual(sawLocal.value, 1)
        XCTAssertFalse(fixture.session.requestTypes.contains(.pointerButton),
                       "the rejected button must never be sent")
    }

    // MARK: Genuine remote failures remain fail-safe (ADR-0011)

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

    func testRequestTimeoutStillFails() {
        // The fake delays 200 ms; the request timeout is 50 ms, so the
        // transport surfaces ConnectionError.timeout.
        let session = FakeSession(delay: 200_000_000)
        let reference = SessionReference()
        reference.set(session)
        let sender = InputSender(session: reference, pointerRequestTimeout: 0.05)
        let result = ResultBox<PointerDeliveryResult>()
        let done = DispatchSemaphore(value: 0)

        sender.enqueuePointer(PointerEvent(.move(dx: 5, dy: 5))) {
            result.set($0)
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(result.get(), .failed,
                       "a timed-out request is a genuine delivery failure")
    }

    func testMalformedPointerResultPayloadStillFails() {
        // Correct frame type, undecodable payload (invalid status byte).
        let session = FakeSession(response: CxiFrame(type: .pointerResult,
                                                      requestId: 1,
                                                      payload: Data([0xAB])))
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
                       "a malformed helper response is a genuine delivery failure")
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
        let fixture = makeFixture()

        // Park a button boundary in flight so the move burst forms one
        // QUEUED batch that merges fully before delivery.
        fixture.sender.enqueuePointer(PointerEvent(.button(button: 0, down: true))) { _ in }
        awaitInFlight(fixture.session)

        // The parked button consumed the gated request; arm the override so
        // the NEXT request (the merged movement batch) gets the partial result.
        fixture.session.respondWith(CxiFrame(
            type: .pointerResult,
            requestId: 1,
            payload: Messages.pointerResult(status: .partiallyDelivered,
                                             deliveredDx: 127,
                                             deliveredDy: 0)))
        // The FIRST enqueue owns the batch's single acknowledgement; later
        // merges keep that original completion by design (ADR-0011).
        let result = ResultBox<PointerDeliveryResult>()
        let done = DispatchSemaphore(value: 0)
        fixture.sender.enqueuePointer(PointerEvent(.move(dx: 150, dy: 0))) {
            result.set($0)
            done.signal()
        }
        fixture.sender.enqueuePointer(PointerEvent(.move(dx: 150, dy: 0))) { _ in }
        fixture.session.releaseGate()
        fixture.sender.waitForDrain()
        XCTAssertEqual(done.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(result.get(), .partiallyDeliveredMovement(requestedDx: 300, requestedDy: 0,
                                                                 deliveredDx: 127, deliveredDy: 0))
    }

    // MARK: Session-generation semantics (ADR-0011)

    func testCoalescedBatchOnReplacedSessionIsCancelledAndNeverDelivered() {
        let oldSession = FakeSession()
        oldSession.gateAllRequests = true
        let newSession = FakeSession()
        let reference = SessionReference()
        reference.set(oldSession)
        let sender = InputSender(session: reference, pointerRequestTimeout: 5)

        sender.enqueuePointer(PointerEvent(.button(button: 0, down: true))) { _ in }
        awaitInFlight(oldSession)

        let staleCallbacks = CompletionCounter()
        sender.enqueuePointer(PointerEvent(.scroll(horizontal: 4, vertical: 4))) { _ in staleCallbacks.call() }
        sender.enqueuePointer(PointerEvent(.scroll(horizontal: 6, vertical: 6))) { _ in staleCallbacks.call() }

        reference.set(newSession)
        oldSession.releaseGate()
        sender.waitForDrain()

        XCTAssertEqual(newSession.requestCount, 0,
                       "stale coalesced work must not reach the replacement session")
        XCTAssertEqual(staleCallbacks.value, 1,
                       "the two scrolls coalesced into ONE batch, so its single "
                       + "owner observes exactly one cancellation")
        XCTAssertEqual(newSession.acceptedScroll.0, 0, accuracy: 0.0001)
    }

    // MARK: Pointer-generation semantics (cancelPendingPointerEvents)

    /// Cancelling the pointer generation must invalidate BOTH queued batches
    /// (immediately) and the in-flight request (when its stale response
    /// arrives). Nothing may be re-sent and no movement credited.
    func testPointerGenerationCancellationCoversQueuedAndInFlightWork() {
        let fixture = makeFixture()

        let inFlightResult = ResultBox<PointerDeliveryResult>()
        let inFlightDone = DispatchSemaphore(value: 0)
        fixture.sender.enqueuePointer(PointerEvent(.move(dx: -100, dy: 0))) { result in
            inFlightResult.set(result)
            inFlightDone.signal()
        }
        awaitInFlight(fixture.session)

        let queuedResults = ResultBox<PointerDeliveryResult>()
        let queuedDone = DispatchSemaphore(value: 0)
        fixture.sender.enqueuePointer(PointerEvent(.move(dx: 1, dy: 0))) { result in
            queuedResults.set(result)
            queuedDone.signal()
        }
        fixture.sender.enqueuePointer(PointerEvent(.scroll(horizontal: 1, vertical: 1))) { result in
            queuedResults.set(result)
            queuedDone.signal()
        }

        fixture.sender.cancelPendingPointerEvents()
        XCTAssertEqual(queuedDone.wait(timeout: .now() + 1), .success,
                       "queued batches are cancelled synchronously")

        fixture.session.releaseGate()
        fixture.sender.waitForDrain()
        XCTAssertEqual(inFlightDone.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(inFlightResult.get(), .cancelled,
                       "a stale in-flight response must surface as cancelled")
        XCTAssertEqual(queuedResults.get(), .cancelled)
        XCTAssertEqual(fixture.session.requestCount, 1,
                       "cancellation must not generate any new remote request")
    }

    /// Sender-level half of the stale-in-flight invariant (issue #45/#63):
    /// a cancelled in-flight return-direction batch reports `.cancelled`,
    /// never a deliverable movement result.
    func testCancelledInFlightDeliveryReportsCancelledResult() {
        let fixture = makeFixture()

        let result = ResultBox<PointerDeliveryResult>()
        let done = DispatchSemaphore(value: 0)
        fixture.sender.enqueuePointer(PointerEvent(.move(dx: -100, dy: 0))) {
            result.set($0)
            done.signal()
        }
        awaitInFlight(fixture.session)

        fixture.sender.cancelPendingPointerEvents()
        fixture.session.releaseGate()
        fixture.sender.waitForDrain()

        XCTAssertEqual(done.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(result.get(), .cancelled,
                       "the invalidated in-flight request must not report delivery")
    }

    /// Controller-level mutation killer for stale in-flight accounting.
    ///
    /// Required structure (hysteresis 60):
    /// 1. remoteActive established.
    /// 2. A successful inward movement consumes the first-movement exemption.
    /// 3. A return-direction -100 request is created and observed in flight.
    /// 4. cancelPendingPointerEvents() bumps the pointer generation.
    /// 5. The stale request then returns success.
    ///
    /// If the generation/stale-result protection were removed, the -100
    /// success would be credited (-100 <= -60), forcing an immediate
    /// boundaryCrossed return; this test asserts the session stays
    /// remoteActive, so that mutation fails the test.
    func testCancelledInFlightReturnMovementNeverCreditsHandoff() async {
        let fixture = makeFixture()
        let machine = EdgeSwitchStateMachine(returnHysteresis: 60)
        let controller = ControlHandoffController(sender: fixture.sender,
                                                  switchMachine: machine)
        let sawLocal = CompletionCounter()
        controller.onStateChange = { state in
            if state == .local { sawLocal.call() }
        }

        machine.activate()
        machine.pointerAtEdge(.right)
        machine.flushCallbacks()
        await settleMainActor()
        XCTAssertEqual(machine.state, .remoteActive)
        sawLocal.reset() // ignore the activation-time local transition

        // Step 2: legitimate inward movement, delivered successfully; this
        // consumes the first-movement exemption.
        controller.capture.onPointerEvent?(PointerEvent(.move(dx: 40, dy: 40)))
        awaitInFlight(fixture.session)
        fixture.session.releaseGate()
        fixture.sender.waitForDrain()
        machine.flushCallbacks()
        await settleMainActor()
        XCTAssertEqual(machine.state, .remoteActive)
        sawLocal.reset() // ignore transitions emitted before the stale phase

        // Steps 3-5: return-direction movement large enough to cross the
        // return threshold if accidentally credited.
        fixture.session.rearmGate()
        controller.capture.onPointerEvent?(PointerEvent(.move(dx: -100, dy: 0)))
        awaitInFlight(fixture.session)
        fixture.sender.cancelPendingPointerEvents()
        fixture.session.releaseGate()
        fixture.sender.waitForDrain()
        machine.flushCallbacks()
        await settleMainActor()

        XCTAssertEqual(machine.state, .remoteActive,
                       "cancelled stale in-flight movement must not force a return")
        XCTAssertEqual(sawLocal.value, 0,
                       "-100 <= -hysteresis must never be credited after cancellation")
    }

    private final class ResultBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value?

        func set(_ value: Value) { lock.withLock { self.value = value } }
        func get() -> Value? { lock.withLock { value } }
        var isNil: Bool { lock.withLock { value == nil } }
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

        /// Signalled synchronously on entry to `request` when the gate is
        /// armed: observing it proves the request is inside the transport,
        /// with no polling and no timing assumptions.
        let requestEntered = DispatchSemaphore(value: 0)

        /// When enabled, requests block inside the fake until `releaseGate()`
        /// is called. The open state LATCHES: after releaseGate(), later
        /// requests pass through freely until `rearmGate()` closes the gate
        /// again for the next request.
        var gateAllRequests = false
        private let gateLock = NSLock()
        private var gateOpen = false

        func releaseGate() {
            gateLock.withLock { gateOpen = true }
        }

        /// Closes the gate again so the NEXT request parks deterministically.
        func rearmGate() {
            gateLock.withLock { gateOpen = false }
        }

        func connect() async throws {}

        init(response: CxiFrame? = nil, delay: UInt64 = 0, sendDelay: UInt64 = 0) {
            self.response = response
            self.delay = delay
            self.sendDelay = sendDelay
        }
        /// Overrides every subsequent response until changed. Used after a
        /// gated request is parked so the override reaches the NEXT request.
        func respondWith(_ frame: CxiFrame) {
            responseBox.lock.withLock { responseBox.value = frame }
        }
        private let responseBox = ResponseBox()

        private final class ResponseBox: @unchecked Sendable {
            let lock = NSLock()
            var value: CxiFrame?
        }

        func request(_ type: MessageType, payload: Data, timeout: TimeInterval?) async throws -> CxiFrame {
            if gateAllRequests, !gateLock.withLock({ gateOpen }) {
                // Prove entry first, then block until the test releases us.
                requestEntered.signal()
                while !gateLock.withLock({ gateOpen }) {
                    try await Task.sleep(nanoseconds: 2_000_000)
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
            if let override = responseBox.lock.withLock({ responseBox.value }) {
                // Sticky: every later request uses this response until
                // respondWith changes or clears it.
                return override
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
            sendStarted.signal()
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
