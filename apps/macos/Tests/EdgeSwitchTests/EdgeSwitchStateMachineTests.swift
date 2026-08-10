import XCTest
@testable import EdgeSwitch

/// Thread-safe collector for transition callbacks (onStateChange is @Sendable).
final class TransitionCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [StateTransition] = []

    var transitions: [StateTransition] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    var reasons: [TransitionReason] {
        lock.lock(); defer { lock.unlock() }
        return storage.map(\.reason)
    }

    func append(_ transition: StateTransition) {
        lock.lock(); defer { lock.unlock() }
        storage.append(transition)
    }
}

final class EdgeSwitchStateMachineTests: XCTestCase {
    /// Common setup: activate -> connect -> ready -> reach the edge -> remoteActive.
    private func makeRemoteActive(edge: ScreenEdge) -> EdgeSwitchStateMachine {
        let machine = EdgeSwitchStateMachine()
        machine.activate()
        machine.connectionBegan()
        machine.connectionReady()
        XCTAssertEqual(machine.state, .localActive)
        machine.pointerAtEdge(edge)
        XCTAssertEqual(machine.state, .remoteActive)
        // Drain async callbacks scheduled before a test installs its own
        // onStateChange; otherwise those transitions leak into the collector.
        machine.flushCallbacks()
        return machine
    }

    // MARK: - Entering: movement toward Android never returns

    func testStaysRemoteActiveWhileMovingIntoAndroidOnLeftEdge() {
        let machine = makeRemoteActive(edge: .left)
        machine.pointerMoved(dx: -1, dy: 0)
        machine.pointerMoved(dx: -60, dy: 0)
        machine.pointerMoved(dx: -500, dy: 0)
        XCTAssertEqual(machine.state, .remoteActive)
    }

    func testStaysRemoteActiveWhileMovingIntoAndroidOnRightEdge() {
        let machine = makeRemoteActive(edge: .right)
        machine.pointerMoved(dx: 1, dy: 0)
        machine.pointerMoved(dx: 60, dy: 0)
        machine.pointerMoved(dx: 500, dy: 0)
        XCTAssertEqual(machine.state, .remoteActive)
    }

    func testStaysRemoteActiveWhileMovingIntoAndroidOnTopEdge() {
        let machine = makeRemoteActive(edge: .top)
        machine.pointerMoved(dx: 0, dy: -1)
        machine.pointerMoved(dx: 0, dy: -60)
        machine.pointerMoved(dx: 0, dy: -500)
        XCTAssertEqual(machine.state, .remoteActive)
    }

    func testStaysRemoteActiveWhileMovingIntoAndroidOnBottomEdge() {
        let machine = makeRemoteActive(edge: .bottom)
        machine.pointerMoved(dx: 0, dy: 1)
        machine.pointerMoved(dx: 0, dy: 60)
        machine.pointerMoved(dx: 0, dy: 500)
        XCTAssertEqual(machine.state, .remoteActive)
    }

    // MARK: - Returning: only after crossing back past the entry boundary + hysteresis

    func testReturnsOnLeftEdgeAfterCrossingHysteresis() {
        let machine = makeRemoteActive(edge: .left)
        // 300 toward Android, then back toward macOS exactly to the boundary.
        machine.pointerMoved(dx: -300, dy: 0)
        machine.pointerMoved(dx: 300, dy: 0)
        XCTAssertEqual(machine.state, .remoteActive, "at the entry boundary")
        // Hysteresis - 1 keeps DeX active.
        machine.pointerMoved(dx: 59, dy: 0)
        XCTAssertEqual(machine.state, .remoteActive, "within the hysteresis band")
        // One more pixel crosses the hysteresis threshold -> macOS.
        machine.pointerMoved(dx: 1, dy: 0)
        XCTAssertEqual(machine.state, .localActive, "crossed hysteresis towards macOS")
    }

    func testReturnsOnRightEdgeAfterCrossingHysteresis() {
        let machine = makeRemoteActive(edge: .right)
        machine.pointerMoved(dx: 300, dy: 0)
        machine.pointerMoved(dx: -300, dy: 0)
        XCTAssertEqual(machine.state, .remoteActive, "at the entry boundary")
        machine.pointerMoved(dx: -59, dy: 0)
        XCTAssertEqual(machine.state, .remoteActive, "within the hysteresis band")
        machine.pointerMoved(dx: -1, dy: 0)
        XCTAssertEqual(machine.state, .localActive, "crossed hysteresis towards macOS")
    }

    func testReturnsOnTopEdgeAfterCrossingHysteresis() {
        let machine = makeRemoteActive(edge: .top)
        machine.pointerMoved(dx: 0, dy: -300)
        machine.pointerMoved(dx: 0, dy: 300)
        XCTAssertEqual(machine.state, .remoteActive, "at the entry boundary")
        machine.pointerMoved(dx: 0, dy: 59)
        XCTAssertEqual(machine.state, .remoteActive, "within the hysteresis band")
        machine.pointerMoved(dx: 0, dy: 1)
        XCTAssertEqual(machine.state, .localActive, "crossed hysteresis towards macOS")
    }

    func testReturnsOnBottomEdgeAfterCrossingHysteresis() {
        let machine = makeRemoteActive(edge: .bottom)
        machine.pointerMoved(dx: 0, dy: 300)
        machine.pointerMoved(dx: 0, dy: -300)
        XCTAssertEqual(machine.state, .remoteActive, "at the entry boundary")
        machine.pointerMoved(dx: 0, dy: -59)
        XCTAssertEqual(machine.state, .remoteActive, "within the hysteresis band")
        machine.pointerMoved(dx: 0, dy: -1)
        XCTAssertEqual(machine.state, .localActive, "crossed hysteresis towards macOS")
    }

    // MARK: - Round trip and orthogonal movement

    func testRoundTripKeepsVirtualPositionAcrossMoves() {
        let machine = makeRemoteActive(edge: .right)
        // +100 / -30 / +20 -> depth 90, still inside Android.
        machine.pointerMoved(dx: 100, dy: 0)
        machine.pointerMoved(dx: -30, dy: 0)
        machine.pointerMoved(dx: 20, dy: 0)
        XCTAssertEqual(machine.state, .remoteActive)
        // Back off the depth (90) plus hysteresis keeps DeX.
        machine.pointerMoved(dx: -90, dy: 0)
        XCTAssertEqual(machine.state, .remoteActive, "back at the entry boundary")
        machine.pointerMoved(dx: -59, dy: 0)
        XCTAssertEqual(machine.state, .remoteActive)
        machine.pointerMoved(dx: -1, dy: 0)
        XCTAssertEqual(machine.state, .localActive)
    }

    func testOrthogonalMovementDoesNotAffectLeftEdge() {
        let machine = makeRemoteActive(edge: .left)
        machine.pointerMoved(dx: 0, dy: 1000)
        machine.pointerMoved(dx: 0, dy: -1000)
        XCTAssertEqual(machine.state, .remoteActive)
    }

    func testOrthogonalMovementDoesNotAffectRightEdge() {
        let machine = makeRemoteActive(edge: .right)
        machine.pointerMoved(dx: 0, dy: 1000)
        machine.pointerMoved(dx: 0, dy: -1000)
        XCTAssertEqual(machine.state, .remoteActive)
    }

    func testOrthogonalMovementDoesNotAffectTopEdge() {
        let machine = makeRemoteActive(edge: .top)
        machine.pointerMoved(dx: 1000, dy: 0)
        machine.pointerMoved(dx: -1000, dy: 0)
        XCTAssertEqual(machine.state, .remoteActive)
    }

    func testOrthogonalMovementDoesNotAffectBottomEdge() {
        let machine = makeRemoteActive(edge: .bottom)
        machine.pointerMoved(dx: 1000, dy: 0)
        machine.pointerMoved(dx: -1000, dy: 0)
        XCTAssertEqual(machine.state, .remoteActive)
    }

    // MARK: - First event rule (issue #37: "first movement after entering is
    // never treated as a return") — the actual fix for the left-edge
    // instant-return bug. origin/main and the virtual-position model are
    // mathematically equivalent for left/right, so this rule (not the delta
    // math) is what stops warp/synthetic leftover deltas from bouncing the
    // user out of DeX right after entering.

    func testFirstMovementInEntryDirectionNeverReturns() {
        // Regression for: entering Android and immediately seeing a large jump.
        // The first movement after entering must never alone switch to macOS,
        // regardless of magnitude, when it points toward Android (or stays
        // within the hysteresis band toward macOS).
        let machine = makeRemoteActive(edge: .right)
        machine.pointerMoved(dx: 1000, dy: 0)
        XCTAssertEqual(machine.state, .remoteActive)
    }

    func testFirstMovementTowardMacOSWithinHysteresisDoesNotReturn() {
        let machine = makeRemoteActive(edge: .right)
        machine.pointerMoved(dx: -1, dy: 0)
        XCTAssertEqual(machine.state, .remoteActive, "tiny wobble toward macOS must not return")
    }

    func testFirstMovementPastHysteresisDoesNotReturnButSecondDoes() {
        // The very first event after entering never returns, even if it is
        // huge and points toward macOS (warp/synthetic leftover), and it is
        // normalized to max(0, delta) so it leaves no negative baseline. The
        // second movement is a real user gesture and normal hysteresis applies.
        let machine = makeRemoteActive(edge: .right)
        machine.pointerMoved(dx: -61, dy: 0)
        XCTAssertEqual(machine.state, .remoteActive, "first event never returns (issue #37)")
        machine.pointerMoved(dx: -61, dy: 0)
        XCTAssertEqual(machine.state, .localActive, "second event past hysteresis returns")
    }

    // MARK: - First-event baseline normalization (issue #37)

    // The first movement after entering is warp/synthetic residual: it is
    // normalized to max(0, delta) — never accumulated as a negative baseline —
    // and never returns. Movement in the entry direction right after must
    // never be poisoned by a macOS-directed residual.

    func testFirstMacDirectedResidualDoesNotPoisonNextAndroidDirectedMove() {
        // Right edge: residual dx=-1000 (toward macOS), then dx=+1 (Android).
        let machine = makeRemoteActive(edge: .right)
        machine.pointerMoved(dx: -1000, dy: 0)
        XCTAssertEqual(machine.state, .remoteActive)
        machine.pointerMoved(dx: 1, dy: 0)
        XCTAssertEqual(machine.state, .remoteActive, "Android-directed move after residual must not return")
    }

    func testFirstResidualIsExcludedFromReturnBaselineForAllEdges() {
        // Left edge: residual dx=+1000 (toward macOS), then dx=-1 (Android).
        let left = makeRemoteActive(edge: .left)
        left.pointerMoved(dx: 1000, dy: 0)
        left.pointerMoved(dx: -1, dy: 0)
        XCTAssertEqual(left.state, .remoteActive)

        // Top edge: residual dy=+1000 (toward macOS = down), then dy=-1 (Android = up).
        let top = makeRemoteActive(edge: .top)
        top.pointerMoved(dx: 0, dy: 1000)
        top.pointerMoved(dx: 0, dy: -1)
        XCTAssertEqual(top.state, .remoteActive)

        // Bottom edge: residual dy=-1000 (toward macOS = up), then dy=+1 (Android = down).
        let bottom = makeRemoteActive(edge: .bottom)
        bottom.pointerMoved(dx: 0, dy: -1000)
        bottom.pointerMoved(dx: 0, dy: 1)
        XCTAssertEqual(bottom.state, .remoteActive)
    }

    func testReturnThresholdCountsOnlyMovementAfterFirstEventNormalization() {
        // First event is clamped to 0; only subsequent macOS-directed movement
        // accumulates toward -returnHysteresis.
        let machine = makeRemoteActive(edge: .right)
        machine.pointerMoved(dx: -1000, dy: 0) // normalized to 0
        XCTAssertEqual(machine.state, .remoteActive)
        machine.pointerMoved(dx: -61, dy: 0) // -61 <= -60 -> return
        XCTAssertEqual(machine.state, .localActive)
    }

    func testFirstNegativeResidualIsNormalized() {
        // Representative regression (directive test): a large macOS-directed
        // residual must not leak into the return baseline, so control returns
        // only after genuine pull-back accumulates past the hysteresis.
        let machine = makeRemoteActive(edge: .right)
        machine.pointerMoved(dx: -1000, dy: 0) // residual -> normalized to 0
        XCTAssertEqual(machine.state, .remoteActive, "first event never returns")
        machine.pointerMoved(dx: -59, dy: 0) // position -59, above -60
        XCTAssertEqual(machine.state, .remoteActive, "not yet past hysteresis")
        machine.pointerMoved(dx: -1, dy: 0) // position -60 -> return
        XCTAssertEqual(machine.state, .localActive)
    }

    func testFirstAndroidDirectedInputIsNormalizedToItsMagnitude() {
        // First event toward Android is acknowledged at its full magnitude
        // (max(0, delta) == delta): a large entry jump creates deep position.
        let machine = makeRemoteActive(edge: .left)
        machine.pointerMoved(dx: -300, dy: 0) // delta = +300 -> position 300
        XCTAssertEqual(machine.state, .remoteActive)
        // Pull back 340 total: 300 - 340 = -40 (still above -60, no return).
        machine.pointerMoved(dx: 40, dy: 0)
        machine.pointerMoved(dx: 300, dy: 0)
        XCTAssertEqual(machine.state, .remoteActive)
        machine.pointerMoved(dx: 20, dy: 0) // -60 -> return
        XCTAssertEqual(machine.state, .localActive)
    }

    // MARK: - Real trace regression (recorded on device, left edge, 2026-08-05)
    // Movement into Android on the left edge: dx negative. This is the actual
    // sequence from the on-device session; it must never return while the user
    // keeps pushing into DeX.

    func testRealLeftEdgeEntryTraceNeverReturns() {
        let trace: [(dx: CGFloat, dy: CGFloat)] = [
            (-25, 20), (-18, 18), (-9, 3), (-12, -4), (-30, 15),
            (-22, 9), (-17, 11), (-40, 2), (-35, -8), (-28, 13),
            (-19, 5), (-11, -2), (-33, 7), (-26, 16), (-14, 4),
            (-8, -6), (-21, 12), (-37, 1), (-24, -9), (-15, 8),
        ]
        let machine = makeRemoteActive(edge: .left)
        for (dx, dy) in trace {
            machine.pointerMoved(dx: dx, dy: dy)
        }
        XCTAssertEqual(machine.state, .remoteActive,
                       "sustained movement toward Android must never return")
    }

    func testRealLeftEdgeReturnTraceReturnsOnlyAfterCrossingHysteresis() {
        // Left edge: user pushed 300 into DeX, then pulled back toward macOS
        // in the recorded event sequence. Return must fire only when the
        // position crosses -60, not on the first pull-back event.
        let machine = makeRemoteActive(edge: .left)
        machine.pointerMoved(dx: -300, dy: 0) // into Android (first event, exempt), pos +300
        let pullBack: [(dx: CGFloat, dy: CGFloat)] = [
            (81, -34), (103, -37), (111, -34), (138, -38),
        ]
        var returned = false
        for (dx, dy) in pullBack {
            machine.pointerMoved(dx: dx, dy: dy)
            if machine.state == .localActive { returned = true; break }
        }
        // left edge: delta = -dx. 300 - 81 - 103 = 116 (still inside),
        // -111 -> 5 (still inside), -138 -> -133 (crosses -60, 4th event).
        XCTAssertTrue(returned, "pull-back past the boundary + hysteresis must return")
        XCTAssertEqual(machine.state, .localActive)
    }

    // MARK: - Equivalence with origin/main (left/right)
    // origin/main: left delta=dx returns when accumulator >= 60 (dx>0 is back
    // toward macOS); right delta=-dx returns when accumulator >= 60 (dx<0 is
    // back toward macOS). The virtual-position model with -returnHysteresis is
    // mathematically identical for these edges; the traces below must behave
    // the same under both models.

    func testLeftEdgeEquivalenceWithOriginMain() {
        let machine = makeRemoteActive(edge: .left)
        // PR: position = -Σdx, return at <= -60  ⟺  Σdx >= 60 (main).
        machine.pointerMoved(dx: -100, dy: 0) // first event: exempt, pos 100
        machine.pointerMoved(dx: -20, dy: 0)  // pos 120
        machine.pointerMoved(dx: -40, dy: 0)  // pos 160
        machine.pointerMoved(dx: 100, dy: 0)  // pos 60; main Σdx=-60 < 60: active
        XCTAssertEqual(machine.state, .remoteActive)
        machine.pointerMoved(dx: 100, dy: 0)  // pos -40; main Σdx=40 < 60: active
        XCTAssertEqual(machine.state, .remoteActive)
        machine.pointerMoved(dx: 20, dy: 0)   // pos -60; main Σdx=60 -> return
        XCTAssertEqual(machine.state, .localActive)
    }

    func testRightEdgeEquivalenceWithOriginMain() {
        let machine = makeRemoteActive(edge: .right)
        // PR: position = Σdx, return at <= -60  ⟺  Σdx <= -60 (main).
        machine.pointerMoved(dx: 100, dy: 0)  // first event: exempt, pos 100
        machine.pointerMoved(dx: 20, dy: 0)   // pos 120
        machine.pointerMoved(dx: 40, dy: 0)   // pos 160
        machine.pointerMoved(dx: -100, dy: 0) // pos 60; main -Σdx=60: active
        XCTAssertEqual(machine.state, .remoteActive)
        machine.pointerMoved(dx: -100, dy: 0) // pos -40; main -Σdx=40: active
        XCTAssertEqual(machine.state, .remoteActive)
        machine.pointerMoved(dx: -20, dy: 0)  // pos -60; main -Σdx=60 -> return
        XCTAssertEqual(machine.state, .localActive)
    }

    // MARK: - Transition reasons (root-cause tracing)

    func testBoundaryCrossedReasonIsReported() {
        let machine = makeRemoteActive(edge: .left)
        let collector = TransitionCollector()
        machine.onStateChange = { collector.append($0) }
        machine.pointerMoved(dx: -100, dy: 0)
        machine.pointerMoved(dx: 160, dy: 0) // pos -60 -> boundary crossed
        machine.flushCallbacks()
        XCTAssertEqual(collector.reasons, [.boundaryCrossed, .boundaryCrossed],
                       "remoteActive -> returning -> localActive, both boundaryCrossed")
    }

    func testConnectionLostReasonIsReported() {
        let machine = makeRemoteActive(edge: .left)
        let collector = TransitionCollector()
        machine.onStateChange = { collector.append($0) }
        machine.connectionLost()
        machine.flushCallbacks()
        XCTAssertEqual(collector.reasons.last, .connectionLost)
        XCTAssertEqual(machine.state, .returning)
    }

    func testEmergencyReturnReasonIsReported() {
        let machine = makeRemoteActive(edge: .left)
        let collector = TransitionCollector()
        machine.onStateChange = { collector.append($0) }
        machine.emergencyReturn(reason: .emergencyReturn)
        machine.flushCallbacks()
        XCTAssertEqual(collector.reasons, [.emergencyReturn, .emergencyReturn])
        XCTAssertEqual(machine.state, .localActive)
    }

    func testSuppressionReleasedReasonIsReported() {
        let machine = makeRemoteActive(edge: .left)
        let collector = TransitionCollector()
        machine.onStateChange = { collector.append($0) }
        machine.emergencyReturn(reason: .suppressionReleased)
        machine.flushCallbacks()
        XCTAssertEqual(collector.reasons, [.suppressionReleased, .suppressionReleased])
    }

    func testWatchdogTimeoutReasonIsReported() {
        let machine = makeRemoteActive(edge: .left)
        let collector = TransitionCollector()
        machine.onStateChange = { collector.append($0) }
        machine.emergencyReturn(reason: .watchdogTimeout)
        machine.flushCallbacks()
        XCTAssertEqual(collector.reasons, [.watchdogTimeout, .watchdogTimeout])
    }

    func testExternalControlTakeoverReasonIsReported() {
        let machine = makeDexActive(edge: .left)
        let collector = TransitionCollector()
        machine.onStateChange = { collector.append($0) }
        machine.emergencyReturn(reason: .externalControlTakeover)
        machine.flushCallbacks()
        XCTAssertEqual(collector.reasons, [.externalControlTakeover, .externalControlTakeover])
        XCTAssertEqual(machine.state, .macActive)
    }

    func testEdgeEnteredReasonIsReported() {
        let machine = EdgeSwitchStateMachine()
        machine.activate()
        machine.connectionBegan()
        machine.connectionReady()
        // Drain pre-registration callbacks so only the entry transitions land.
        machine.flushCallbacks()
        let collector = TransitionCollector()
        machine.onStateChange = { collector.append($0) }
        machine.pointerAtEdge(.left)
        machine.flushCallbacks()
        XCTAssertEqual(collector.reasons, [.edgeEntered, .edgeEntered],
                       "localActive -> edgeArmed -> remoteActive, both edgeEntered")
    }

    func testActivationAndConnectionReasonsAreReported() {
        let machine = EdgeSwitchStateMachine()
        let collector = TransitionCollector()
        machine.onStateChange = { collector.append($0) }
        machine.activate()
        machine.connectionBegan()
        machine.connectionReady()
        machine.flushCallbacks()
        XCTAssertEqual(collector.reasons, [.activation, .connectionBegan, .connectionReady])
    }

    // MARK: - Fail-safes

    func testFailSafeEmergencyReturnGoesToLocalActive() {
        for edge in [ScreenEdge.left, .right, .top, .bottom] {
            let machine = makeRemoteActive(edge: edge)
            machine.emergencyReturn()
            XCTAssertEqual(machine.state, .localActive, "\(edge)")
        }
    }

    func testFailSafeConnectionLostWhileRemoteActiveGoesToReturning() {
        let machine = makeRemoteActive(edge: .left)
        machine.connectionLost()
        XCTAssertEqual(machine.state, .returning)
    }

    func testMovementWhileLocalActiveHasNoEffect() {
        let machine = EdgeSwitchStateMachine()
        machine.activate()
        machine.connectionBegan()
        machine.connectionReady()
        XCTAssertEqual(machine.state, .localActive)
        machine.pointerMoved(dx: -1000, dy: 0)
        XCTAssertEqual(machine.state, .localActive)
    }

    func testMovementWhileDisabledHasNoEffect() {
        let machine = EdgeSwitchStateMachine()
        machine.pointerMoved(dx: -1000, dy: 0)
        XCTAssertEqual(machine.state, .disabled)
    }

    func testMovementAfterReturnToMacOSHasNoEffect() {
        let machine = makeRemoteActive(edge: .right)
        machine.pointerMoved(dx: 300, dy: 0)
        machine.pointerMoved(dx: -360, dy: 0)
        XCTAssertEqual(machine.state, .localActive)
        machine.pointerMoved(dx: -1000, dy: 0)
        XCTAssertEqual(machine.state, .localActive)
    }

    // MARK: - Re-entering resets the virtual position

    func testReenteringEdgeResetsVirtualPosition() {
        // Enter -> return -> re-enter. The stale position from the first session
        // must be reset; a small wobble after re-entering must not return.
        let machine = makeRemoteActive(edge: .right)
        machine.pointerMoved(dx: 300, dy: 0)
        machine.pointerMoved(dx: -360, dy: 0)
        XCTAssertEqual(machine.state, .localActive)

        machine.pointerAtEdge(.right)
        XCTAssertEqual(machine.state, .remoteActive)
        machine.pointerMoved(dx: -30, dy: 0) // first event after re-entry, normalized to 0
        machine.pointerMoved(dx: -61, dy: 0) // second: -61 past hysteresis
        XCTAssertEqual(machine.state, .localActive)
    }

    // MARK: - Virtual position matches UHID-delivered movement

    // main.swift feeds the state machine with the splitter's deliveredDx/dy
    // (not the raw Int32), so the virtual position must equal what Android
    // actually received. These tests prove the machine behaves identically
    // whether fed raw or per-report values (directive #2 synchronization).

    func testVirtualPositionMatchesDeliveredSumWhenFeedingSplitReports() {
        // dx=300 -> reports [127, 127, 46]. Feeding each report individually
        // must accumulate to the same 300 position as one raw call.
        let raw = HIDReportSplitter.normalizeForHID(dx: 300, dy: 0)
        XCTAssertEqual(raw.deliveredDx, 300)

        let perReport = makeRemoteActive(edge: .right)
        for report in raw.reports {
            perReport.pointerMoved(dx: CGFloat(report.dx), dy: CGFloat(report.dy))
        }
        XCTAssertEqual(perReport.state, .remoteActive)

        // Pull back 361 in split form: 300 - 361 = -61 -> past hysteresis.
        let pull = HIDReportSplitter.normalizeForHID(dx: -361, dy: 0)
        for report in pull.reports {
            perReport.pointerMoved(dx: CGFloat(report.dx), dy: CGFloat(report.dy))
        }
        XCTAssertEqual(perReport.state, .localActive)
    }

    func testVirtualPositionMatchesDeliveredWhenFedOncePerEvent() {
        // One pointerMoved call with the delivered total behaves identically
        // to per-report feeding (the send(event:) path in main.swift).
        let machine = makeRemoteActive(edge: .right)
        machine.pointerMoved(dx: 300, dy: 0)
        machine.pointerMoved(dx: -359, dy: 0) // 300 - 359 = -59: not yet
        XCTAssertEqual(machine.state, .remoteActive)
        machine.pointerMoved(dx: -2, dy: 0) // -61: past hysteresis
        XCTAssertEqual(machine.state, .localActive)
    }

    // MARK: - Fatal error survives suppression release

    func testFatalStateIsPreservedThroughEmergencyReturn() {
        // helper fatal -> .error. A subsequent suppression release calls
        // emergencyReturn(), which must NOT move the machine out of .error
        // (the app phase stays .error via SuppressionPhasePolicy).
        let machine = makeRemoteActive(edge: .left)
        let collector = TransitionCollector()
        machine.onStateChange = { collector.append($0) }
        machine.fatal()
        machine.flushCallbacks()
        XCTAssertEqual(machine.state, .error)
        XCTAssertEqual(collector.reasons.last, .fatalError)

        machine.emergencyReturn(reason: .fatalError)
        XCTAssertEqual(machine.state, .error, "fatal error must not be covered by a release")
    }

    func testFatalThenConnectionReadyCannotReviveFromError() {
        let machine = makeRemoteActive(edge: .left)
        machine.fatal()
        machine.connectionReady()
        XCTAssertEqual(machine.state, .error, "error is terminal until explicit deactivate")
        machine.deactivate() // explicit recovery path: deactivate -> activate
        XCTAssertEqual(machine.state, .disabled)
        machine.activate()
        XCTAssertEqual(machine.state, .disconnected)
    }

    // MARK: - Send failure: only delivered movement is credited

    func testFailedSendIsNotCreditedToVirtualPosition() {
        // UHID path: a fully failed send delivers (0,0) and must be a complete
        // no-op — it neither credits position nor consumes the first-event
        // exemption. A later successful -61 is then the FIRST real movement,
        // so it is normalized to 0 and does not return; the following -61 is
        // the one that crosses the hysteresis.
        let machine = makeRemoteActive(edge: .right)
        machine.pointerMoved(dx: 0, dy: 0) // failed send: no-op
        XCTAssertEqual(machine.state, .remoteActive)
        machine.pointerMoved(dx: -61, dy: 0) // first real movement: normalized to 0
        XCTAssertEqual(machine.state, .remoteActive, "zero delivery must not consume the first-move exemption")
        machine.pointerMoved(dx: -61, dy: 0) // second: -61 -> return
        XCTAssertEqual(machine.state, .localActive)
    }

    func testPartialDeliveryCreditsOnlySentReports() {
        // dx=300 -> [127,127,46]. If the third report fails, the machine is
        // credited 254, not 300 — pull-back must cross from 254, not 300.
        // Failed reports are simply not fed to the machine (never a (0,0)
        // placeholder call, which is now a no-op).
        let machine = makeRemoteActive(edge: .right)
        machine.pointerMoved(dx: 127, dy: 0)
        machine.pointerMoved(dx: 127, dy: 0)
        // Third report failed: no pointerMoved call at all.
        // Position is 254; -313 -> -59 (not yet), -2 -> -61 (return).
        machine.pointerMoved(dx: -313, dy: 0)
        XCTAssertEqual(machine.state, .remoteActive)
        machine.pointerMoved(dx: -2, dy: 0)
        XCTAssertEqual(machine.state, .localActive)
    }

    // MARK: - Concurrent transitions stay consistent

    func testConcurrentEmergencyReturnAndPointerMovement() {
        let machine = makeRemoteActive(edge: .left)
        let expectations = (0..<8).map { _ in expectation(description: "worker") }
        DispatchQueue.concurrentPerform(iterations: 8) { i in
            if i.isMultiple(of: 2) {
                machine.emergencyReturn(reason: .emergencyReturn)
            } else {
                machine.pointerMoved(dx: -500, dy: 0)
            }
            expectations[i].fulfill()
        }
        wait(for: expectations, timeout: 5)
        // Serialized queue: the final state is one of the valid outcomes,
        // never a torn intermediate (e.g. .edgeArmed from a concurrent entry).
        XCTAssertTrue(machine.state == .localActive || machine.state == .remoteActive)
    }

    func testConcurrentConnectionLostAndPointerAtEdge() {
        let machine = EdgeSwitchStateMachine()
        machine.activate()
        machine.connectionBegan()
        machine.connectionReady()
        DispatchQueue.concurrentPerform(iterations: 10) { i in
            if i.isMultiple(of: 2) {
                machine.connectionLost()
            } else {
                machine.pointerAtEdge(.left)
            }
        }
        // Either .returning (if connectionLost won) or a valid edge-armed
        // chain from localActive — never a state that the serialized transitions
        // cannot produce.
        XCTAssertTrue([.returning, .edgeArmed, .remoteActive, .connecting].contains(machine.state),
                      "unexpected state after concurrent transitions: \(machine.state.rawValue)")
    }

    // MARK: - Zero delivery never consumes the first-movement exemption (directive 3.1)

    func testZeroDeliveredMovementDoesNotConsumeFirstMovementExemption() {
        let machine = makeRemoteActive(edge: .right)
        machine.pointerMoved(dx: 0, dy: 0) // no-op: must not touch hasReceivedFirstMove
        XCTAssertEqual(machine.state, .remoteActive)
        machine.pointerMoved(dx: -1000, dy: 0) // FIRST real movement: normalized to 0
        XCTAssertEqual(machine.state, .remoteActive, "-1000 is the first real event and must be normalized")
        machine.pointerMoved(dx: -61, dy: 0) // second real: crosses hysteresis
        XCTAssertEqual(machine.state, .localActive)
    }

    // MARK: - Deterministic callback-order inversion (directive 3.2)

    func testConcurrentMutationsPreserveTransitionApplicationOrder() {
        // Pause the VERY FIRST callback (edgeArmed) while the state machine
        // has already finished mutating to .remoteActive; run fatal() from
        // another queue; then unblock. The observed logical order must be
        // edgeArmed -> remoteActive -> error, never edgeArmed -> error -> remoteActive.
        let machine = EdgeSwitchStateMachine()
        machine.activate()
        machine.connectionBegan()
        machine.connectionReady()
        // Drain activation/connection callbacks before registering the
        // blocking handler (directive 3.2: deterministic callback inversion).
        machine.flushCallbacks()

        let gate = DispatchSemaphore(value: 0)
        let collector = TransitionCollector()
        machine.onStateChange = { transition in
            collector.append(transition)
            if transition.to == .edgeArmed {
                gate.wait() // block the first callback until the test releases it
            }
        }

        // Start pointerAtEdge on a background thread: it mutates to .remoteActive
        // and begins firing; the first callback blocks on the gate.
        let entryDone = expectation(description: "entry-finished")
        DispatchQueue.global(qos: .userInitiated).async {
            machine.pointerAtEdge(.left)
            entryDone.fulfill()
        }

        // Wait until the edgeArmed callback is observed (blocked), then let
        // a second thread run fatal() while the first callback is paused.
        let edgeObserved = expectation(description: "edge-armed-observed")
        DispatchQueue.global(qos: .utility).async {
            while !collector.transitions.contains(where: { $0.to == .edgeArmed }) {
                usleep(1_000)
            }
            edgeObserved.fulfill()
        }
        wait(for: [edgeObserved], timeout: 5)

        let fatalDone = expectation(description: "fatal-done")
        DispatchQueue.global(qos: .userInitiated).async {
            machine.fatal()
            fatalDone.fulfill()
        }
        // Give fatal() a chance to enter the queue while the first callback
        // is still blocked.
        wait(for: [fatalDone], timeout: 5)

        gate.signal() // release the paused first callback

        // Wait for the fatal callback to land too.
        let fatalObserved = expectation(description: "fatal-observed")
        DispatchQueue.global(qos: .utility).async {
            while !collector.reasons.contains(.fatalError) {
                usleep(1_000)
            }
            fatalObserved.fulfill()
        }
        wait(for: [fatalObserved, entryDone], timeout: 5)

        XCTAssertEqual(machine.state, .error)
        // Logical order must be preserved: every transition with a lower
        // sequence is applied before one with a higher sequence.
        let sequences = collector.transitions.map(\.sequence)
        XCTAssertEqual(sequences, sequences.sorted(), "callbacks must fire in sequence order")
        let toStates = collector.transitions.map(\.to)
        if toStates.contains(.remoteActive) {
            let dexIndex = toStates.firstIndex(of: .remoteActive)!
            let errIndex = toStates.firstIndex(of: .error)!
            XCTAssertLessThan(dexIndex, errIndex,
                              "edgeArmed -> remoteActive -> error order violated: \(toStates)")
        }
    }

    // MARK: - Stale-transition gate (directive 3.3)

    func testStaleSequenceIsDiscardedByGate() {
        var gate = TransitionSequenceGate()
        let error = StateTransition(sequence: 11, from: .returning, to: .error, reason: .fatalError)
        let staleDex = StateTransition(sequence: 10, from: .edgeArmed, to: .remoteActive, reason: .edgeEntered)

        XCTAssertTrue(gate.shouldApply(error))
        XCTAssertEqual(gate.lastAppliedSequence, 11)

        XCTAssertFalse(gate.shouldApply(staleDex), "lower sequence must be discarded")
        XCTAssertEqual(gate.lastAppliedSequence, 11, "gate must stay on the newer sequence")
    }

    func testGateRejectsEqualSequenceDuplicate() {
        var gate = TransitionSequenceGate()
        let t = StateTransition(sequence: 5, from: .localActive, to: .remoteActive, reason: .edgeEntered)
        XCTAssertTrue(gate.shouldApply(t))
        XCTAssertFalse(gate.shouldApply(t), "identical sequence is a duplicate, not newer")
        XCTAssertEqual(gate.lastAppliedSequence, 5)
    }

    // MARK: - Fatal / connection loss can never be re-suppressed (directive 3.4)

    func testFatalInterleavedWithEntryNeverReentersRemoteActive() {
        let machine = makeRemoteActive(edge: .left)
        machine.fatal()
        XCTAssertEqual(machine.state, .error)
        machine.pointerAtEdge(.left) // parked entry attempt after fatal
        XCTAssertEqual(machine.state, .error, "entry must not revive .error")
        machine.pointerMoved(dx: -500, dy: 0)
        XCTAssertEqual(machine.state, .error, "movement must not suppress after fatal")
    }

    func testConnectionLostInterleavedWithEntryNeverReentersRemoteActive() {
        let machine = makeRemoteActive(edge: .left)
        machine.connectionLost()
        XCTAssertEqual(machine.state, .returning)
        machine.pointerAtEdge(.left)
        XCTAssertEqual(machine.state, .returning, "entry must not revive a lost connection")
        machine.pointerMoved(dx: -500, dy: 0)
        XCTAssertEqual(machine.state, .returning, "pointer must stay released")
    }

    // MARK: - Callback enqueue order preservation (directive 2)

    /// Thread-safe collector for transition sequences.
    private final class SequenceCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [UInt64] = []

        var sequences: [UInt64] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }

        func append(_ sequence: UInt64) {
            lock.lock(); defer { lock.unlock() }
            storage.append(sequence)
        }
    }

    /// Creates a state machine in .localActive state, ready for mutation.
    private func makeLocalActive() -> EdgeSwitchStateMachine {
        let machine = EdgeSwitchStateMachine()
        machine.activate()
        machine.connectionBegan()
        machine.connectionReady()
        machine.flushCallbacks() // drain setup callbacks
        return machine
    }

    func testConcurrentMutationsEnqueueCallbacksInSequenceOrder() {
        let machine = makeLocalActive()
        let collector = SequenceCollector()

        machine.onStateChange = { transition in
            collector.append(transition.sequence)
        }

        let iterations = 50

        for _ in 0..<iterations {
            // Start gate: two tasks wait, then fire simultaneously
            let startGate = DispatchSemaphore(value: 0)
            let group = DispatchGroup()

            // Task 1: deactivate()
            group.enter()
            DispatchQueue.global().async {
                startGate.wait()
                machine.deactivate()
                group.leave()
            }

            // Task 2: fatal()
            group.enter()
            DispatchQueue.global().async {
                startGate.wait()
                machine.fatal()
                group.leave()
            }

            // Release both tasks simultaneously
            startGate.signal()
            startGate.signal()

            group.wait()

            // Recover to .localActive for the next iteration
            if machine.state == .error {
                machine.deactivate()
            }
            if machine.state == .disabled {
                machine.activate()
            }
            if machine.state == .disconnected {
                machine.connectionBegan()
            }
            if machine.state == .connecting {
                machine.connectionReady()
            }
            machine.flushCallbacks()
            XCTAssertEqual(machine.state, .localActive, "iteration must end in .localActive")
        }

        let sequences = collector.sequences

        // Each iteration fires at minimum: deactivate (->disabled), fatal (->error),
        // recovery: deactivate (error->disabled), activate (->disconnected),
        // connectionBegan (->connecting), connectionReady (->localActive) = 6 transitions
        // Some transitions may be skipped if state already matches, so require >= 5
        XCTAssertGreaterThanOrEqual(
            sequences.count,
            iterations * 5,
            "expected at least \(iterations * 5) transitions, got \(sequences.count)"
        )

        // Sequences must be strictly increasing with no gaps (current == previous + 1)
        // This proves callbacks were enqueued in exact sequence order with no loss
        for i in 1..<sequences.count {
            XCTAssertEqual(
                sequences[i],
                sequences[i - 1] + 1,
                "callback missing or out of order at index \(i): \(sequences[i - 1]) -> \(sequences[i])"
            )
        }

        // No duplicate sequences
        let uniqueCount = Set(sequences).count
        XCTAssertEqual(uniqueCount, sequences.count, "duplicate sequences detected")
    }

    // MARK: - Fatal recovery & stale-release regression (directive 5)

    /// Fatal error state must be recoverable through explicit Connect:
    /// error -> deactivate -> activate -> connectionBegan -> connectionReady -> localActive
    func testFatalThenConnectRecoversStateMachine() {
        let machine = makeRemoteActive(edge: .left)
        machine.fatal()
        XCTAssertEqual(machine.state, .error)

        // Simulate user-initiated fresh Connect: explicit recovery boundary
        machine.deactivate()
        XCTAssertEqual(machine.state, .disabled)
        machine.activate()
        XCTAssertEqual(machine.state, .disconnected)
        machine.connectionBegan()
        XCTAssertEqual(machine.state, .connecting)
        machine.connectionReady()
        XCTAssertEqual(machine.state, .localActive)
    }

    /// Stale normal release after fatal must not overwrite .error phase.
    /// TransitionSequenceGate discards stale transition; phase stays .error.
    func testStaleNormalReleaseAfterFatalDoesNotOverwriteError() {
        let machine = makeRemoteActive(edge: .left)
        machine.fatal()
        XCTAssertEqual(machine.state, .error)

        // Stale normal release callback (as if from a prior suppression session)
        // attempts to drive phase back to .ready. The gate must reject it.
        var gate = TransitionSequenceGate()
        let fatalTransition = StateTransition(sequence: 5, from: .remoteActive, to: .error, reason: .fatalError)
        let staleNormalRelease = StateTransition(sequence: 4, from: .returning, to: .localActive, reason: .suppressionReleased)

        XCTAssertTrue(gate.shouldApply(fatalTransition), "fatal transition applied")
        XCTAssertFalse(gate.shouldApply(staleNormalRelease), "stale normal release discarded")
        XCTAssertEqual(gate.lastAppliedSequence, 5)
    }

    /// Stale normal release after connection loss must not set phase to .ready.
    func testStaleNormalReleaseAfterConnectionLostDoesNotSetReady() {
        let machine = makeRemoteActive(edge: .left)
        machine.connectionLost()
        XCTAssertEqual(machine.state, .returning)

        var gate = TransitionSequenceGate()
        let lostTransition = StateTransition(sequence: 7, from: .remoteActive, to: .returning, reason: .connectionLost)
        let staleNormalRelease = StateTransition(sequence: 6, from: .returning, to: .localActive, reason: .suppressionReleased)

        XCTAssertTrue(gate.shouldApply(lostTransition))
        XCTAssertFalse(gate.shouldApply(staleNormalRelease))
        XCTAssertEqual(gate.lastAppliedSequence, 7)
    }

    /// Suppression release from an older generation must be discarded.
    /// Simulated by feeding a stale sequence to TransitionSequenceGate.
    func testStaleReleaseFromOldGenerationDiscarded() {
        var gate = TransitionSequenceGate()
        let current = StateTransition(sequence: 10, from: .returning, to: .localActive, reason: .suppressionReleased)
        let stale = StateTransition(sequence: 9, from: .returning, to: .localActive, reason: .suppressionReleased)

        XCTAssertTrue(gate.shouldApply(current))
        XCTAssertFalse(gate.shouldApply(stale), "older generation release must be discarded")
        XCTAssertEqual(gate.lastAppliedSequence, 10)
    }

    /// Non-fatal connection loss followed by fresh Connect recovers via returning -> connecting -> localActive.
    func testConnectionLostThenFreshConnectRecoversViaReturning() {
        let machine = makeRemoteActive(edge: .left)
        machine.connectionLost()
        XCTAssertEqual(machine.state, .returning)

        // Fresh Connect path: connectionBegan -> connectionReady -> localActive
        machine.connectionBegan()
        XCTAssertEqual(machine.state, .connecting)
        machine.connectionReady()
        XCTAssertEqual(machine.state, .localActive)
    }

    /// Normal boundary return with live connection transitions to localActive and phase ready.
    func testNormalBoundaryReturnWithLiveConnection() {
        let machine = makeRemoteActive(edge: .right)
        machine.pointerMoved(dx: 300, dy: 0) // deep into Android
        machine.pointerMoved(dx: -360, dy: 0) // crosses boundary + hysteresis
        XCTAssertEqual(machine.state, .localActive)
    }

    /// Watchdog/emergency hotkey release immediately returns to localActive via returning.
    func testWatchdogAndEmergencyHotkeyReleaseImmediately() {
        let machine = makeRemoteActive(edge: .left)

        // Watchdog timeout path: emergencyReturn transitions returning -> localActive
        machine.emergencyReturn(reason: .watchdogTimeout)
        XCTAssertEqual(machine.state, .localActive)

        // Emergency hotkey path
        machine.pointerAtEdge(.left)
        machine.emergencyReturn(reason: .emergencyReturn)
        XCTAssertEqual(machine.state, .localActive)
    }
}
