import XCTest
@testable import EdgeSwitch

/// Thread-safe collector for transition callbacks (onStateChange is @Sendable).
final class TransitionCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(SwitchState, TransitionReason)] = []

    var transitions: [(SwitchState, TransitionReason)] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func append(_ state: SwitchState, _ reason: TransitionReason) {
        lock.lock(); defer { lock.unlock() }
        storage.append((state, reason))
    }
}

final class EdgeSwitchStateMachineTests: XCTestCase {
    /// Common setup: activate -> connect -> ready -> reach the edge -> dexActive.
    private func makeDexActive(edge: ScreenEdge) -> EdgeSwitchStateMachine {
        let machine = EdgeSwitchStateMachine()
        machine.activate()
        machine.connectionBegan()
        machine.connectionReady()
        XCTAssertEqual(machine.state, .macActive)
        machine.pointerAtEdge(edge)
        XCTAssertEqual(machine.state, .dexActive)
        return machine
    }

    // MARK: - Entering: movement toward Android never returns

    func testStaysDexActiveWhileMovingIntoAndroidOnLeftEdge() {
        let machine = makeDexActive(edge: .left)
        machine.pointerMoved(dx: -1, dy: 0)
        machine.pointerMoved(dx: -60, dy: 0)
        machine.pointerMoved(dx: -500, dy: 0)
        XCTAssertEqual(machine.state, .dexActive)
    }

    func testStaysDexActiveWhileMovingIntoAndroidOnRightEdge() {
        let machine = makeDexActive(edge: .right)
        machine.pointerMoved(dx: 1, dy: 0)
        machine.pointerMoved(dx: 60, dy: 0)
        machine.pointerMoved(dx: 500, dy: 0)
        XCTAssertEqual(machine.state, .dexActive)
    }

    func testStaysDexActiveWhileMovingIntoAndroidOnTopEdge() {
        let machine = makeDexActive(edge: .top)
        machine.pointerMoved(dx: 0, dy: -1)
        machine.pointerMoved(dx: 0, dy: -60)
        machine.pointerMoved(dx: 0, dy: -500)
        XCTAssertEqual(machine.state, .dexActive)
    }

    func testStaysDexActiveWhileMovingIntoAndroidOnBottomEdge() {
        let machine = makeDexActive(edge: .bottom)
        machine.pointerMoved(dx: 0, dy: 1)
        machine.pointerMoved(dx: 0, dy: 60)
        machine.pointerMoved(dx: 0, dy: 500)
        XCTAssertEqual(machine.state, .dexActive)
    }

    // MARK: - Returning: only after crossing back past the entry boundary + hysteresis

    func testReturnsOnLeftEdgeAfterCrossingHysteresis() {
        let machine = makeDexActive(edge: .left)
        // 300 toward Android, then back toward macOS exactly to the boundary.
        machine.pointerMoved(dx: -300, dy: 0)
        machine.pointerMoved(dx: 300, dy: 0)
        XCTAssertEqual(machine.state, .dexActive, "at the entry boundary")
        // Hysteresis - 1 keeps DeX active.
        machine.pointerMoved(dx: 59, dy: 0)
        XCTAssertEqual(machine.state, .dexActive, "within the hysteresis band")
        // One more pixel crosses the hysteresis threshold -> macOS.
        machine.pointerMoved(dx: 1, dy: 0)
        XCTAssertEqual(machine.state, .macActive, "crossed hysteresis towards macOS")
    }

    func testReturnsOnRightEdgeAfterCrossingHysteresis() {
        let machine = makeDexActive(edge: .right)
        machine.pointerMoved(dx: 300, dy: 0)
        machine.pointerMoved(dx: -300, dy: 0)
        XCTAssertEqual(machine.state, .dexActive, "at the entry boundary")
        machine.pointerMoved(dx: -59, dy: 0)
        XCTAssertEqual(machine.state, .dexActive, "within the hysteresis band")
        machine.pointerMoved(dx: -1, dy: 0)
        XCTAssertEqual(machine.state, .macActive, "crossed hysteresis towards macOS")
    }

    func testReturnsOnTopEdgeAfterCrossingHysteresis() {
        let machine = makeDexActive(edge: .top)
        machine.pointerMoved(dx: 0, dy: -300)
        machine.pointerMoved(dx: 0, dy: 300)
        XCTAssertEqual(machine.state, .dexActive, "at the entry boundary")
        machine.pointerMoved(dx: 0, dy: 59)
        XCTAssertEqual(machine.state, .dexActive, "within the hysteresis band")
        machine.pointerMoved(dx: 0, dy: 1)
        XCTAssertEqual(machine.state, .macActive, "crossed hysteresis towards macOS")
    }

    func testReturnsOnBottomEdgeAfterCrossingHysteresis() {
        let machine = makeDexActive(edge: .bottom)
        machine.pointerMoved(dx: 0, dy: 300)
        machine.pointerMoved(dx: 0, dy: -300)
        XCTAssertEqual(machine.state, .dexActive, "at the entry boundary")
        machine.pointerMoved(dx: 0, dy: -59)
        XCTAssertEqual(machine.state, .dexActive, "within the hysteresis band")
        machine.pointerMoved(dx: 0, dy: -1)
        XCTAssertEqual(machine.state, .macActive, "crossed hysteresis towards macOS")
    }

    // MARK: - Round trip and orthogonal movement

    func testRoundTripKeepsVirtualPositionAcrossMoves() {
        let machine = makeDexActive(edge: .right)
        // +100 / -30 / +20 -> depth 90, still inside Android.
        machine.pointerMoved(dx: 100, dy: 0)
        machine.pointerMoved(dx: -30, dy: 0)
        machine.pointerMoved(dx: 20, dy: 0)
        XCTAssertEqual(machine.state, .dexActive)
        // Back off the depth (90) plus hysteresis keeps DeX.
        machine.pointerMoved(dx: -90, dy: 0)
        XCTAssertEqual(machine.state, .dexActive, "back at the entry boundary")
        machine.pointerMoved(dx: -59, dy: 0)
        XCTAssertEqual(machine.state, .dexActive)
        machine.pointerMoved(dx: -1, dy: 0)
        XCTAssertEqual(machine.state, .macActive)
    }

    func testOrthogonalMovementDoesNotAffectLeftEdge() {
        let machine = makeDexActive(edge: .left)
        machine.pointerMoved(dx: 0, dy: 1000)
        machine.pointerMoved(dx: 0, dy: -1000)
        XCTAssertEqual(machine.state, .dexActive)
    }

    func testOrthogonalMovementDoesNotAffectRightEdge() {
        let machine = makeDexActive(edge: .right)
        machine.pointerMoved(dx: 0, dy: 1000)
        machine.pointerMoved(dx: 0, dy: -1000)
        XCTAssertEqual(machine.state, .dexActive)
    }

    func testOrthogonalMovementDoesNotAffectTopEdge() {
        let machine = makeDexActive(edge: .top)
        machine.pointerMoved(dx: 1000, dy: 0)
        machine.pointerMoved(dx: -1000, dy: 0)
        XCTAssertEqual(machine.state, .dexActive)
    }

    func testOrthogonalMovementDoesNotAffectBottomEdge() {
        let machine = makeDexActive(edge: .bottom)
        machine.pointerMoved(dx: 1000, dy: 0)
        machine.pointerMoved(dx: -1000, dy: 0)
        XCTAssertEqual(machine.state, .dexActive)
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
        let machine = makeDexActive(edge: .right)
        machine.pointerMoved(dx: 1000, dy: 0)
        XCTAssertEqual(machine.state, .dexActive)
    }

    func testFirstMovementTowardMacOSWithinHysteresisDoesNotReturn() {
        let machine = makeDexActive(edge: .right)
        machine.pointerMoved(dx: -1, dy: 0)
        XCTAssertEqual(machine.state, .dexActive, "tiny wobble toward macOS must not return")
    }

    func testFirstMovementPastHysteresisDoesNotReturnButSecondDoes() {
        // The very first event after entering never returns, even if it is
        // huge and points toward macOS (warp/synthetic leftover), and it is
        // normalized to max(0, delta) so it leaves no negative baseline. The
        // second movement is a real user gesture and normal hysteresis applies.
        let machine = makeDexActive(edge: .right)
        machine.pointerMoved(dx: -61, dy: 0)
        XCTAssertEqual(machine.state, .dexActive, "first event never returns (issue #37)")
        machine.pointerMoved(dx: -61, dy: 0)
        XCTAssertEqual(machine.state, .macActive, "second event past hysteresis returns")
    }

    // MARK: - First-event baseline normalization (issue #37)

    // The first movement after entering is warp/synthetic residual: it is
    // normalized to max(0, delta) — never accumulated as a negative baseline —
    // and never returns. Movement in the entry direction right after must
    // never be poisoned by a macOS-directed residual.

    func testFirstMacDirectedResidualDoesNotPoisonNextAndroidDirectedMove() {
        // Right edge: residual dx=-1000 (toward macOS), then dx=+1 (Android).
        let machine = makeDexActive(edge: .right)
        machine.pointerMoved(dx: -1000, dy: 0)
        XCTAssertEqual(machine.state, .dexActive)
        machine.pointerMoved(dx: 1, dy: 0)
        XCTAssertEqual(machine.state, .dexActive, "Android-directed move after residual must not return")
    }

    func testFirstResidualIsExcludedFromReturnBaselineForAllEdges() {
        // Left edge: residual dx=+1000 (toward macOS), then dx=-1 (Android).
        let left = makeDexActive(edge: .left)
        left.pointerMoved(dx: 1000, dy: 0)
        left.pointerMoved(dx: -1, dy: 0)
        XCTAssertEqual(left.state, .dexActive)

        // Top edge: residual dy=+1000 (toward macOS = down), then dy=-1 (Android = up).
        let top = makeDexActive(edge: .top)
        top.pointerMoved(dx: 0, dy: 1000)
        top.pointerMoved(dx: 0, dy: -1)
        XCTAssertEqual(top.state, .dexActive)

        // Bottom edge: residual dy=-1000 (toward macOS = up), then dy=+1 (Android = down).
        let bottom = makeDexActive(edge: .bottom)
        bottom.pointerMoved(dx: 0, dy: -1000)
        bottom.pointerMoved(dx: 0, dy: 1)
        XCTAssertEqual(bottom.state, .dexActive)
    }

    func testReturnThresholdCountsOnlyMovementAfterFirstEventNormalization() {
        // First event is clamped to 0; only subsequent macOS-directed movement
        // accumulates toward -returnHysteresis.
        let machine = makeDexActive(edge: .right)
        machine.pointerMoved(dx: -1000, dy: 0) // normalized to 0
        XCTAssertEqual(machine.state, .dexActive)
        machine.pointerMoved(dx: -61, dy: 0) // -61 <= -60 -> return
        XCTAssertEqual(machine.state, .macActive)
    }

    func testFirstNegativeResidualIsNormalized() {
        // Representative regression (directive test): a large macOS-directed
        // residual must not leak into the return baseline, so control returns
        // only after genuine pull-back accumulates past the hysteresis.
        let machine = makeDexActive(edge: .right)
        machine.pointerMoved(dx: -1000, dy: 0) // residual -> normalized to 0
        XCTAssertEqual(machine.state, .dexActive, "first event never returns")
        machine.pointerMoved(dx: -59, dy: 0) // position -59, above -60
        XCTAssertEqual(machine.state, .dexActive, "not yet past hysteresis")
        machine.pointerMoved(dx: -1, dy: 0) // position -60 -> return
        XCTAssertEqual(machine.state, .macActive)
    }

    func testFirstAndroidDirectedInputIsNormalizedToItsMagnitude() {
        // First event toward Android is acknowledged at its full magnitude
        // (max(0, delta) == delta): a large entry jump creates deep position.
        let machine = makeDexActive(edge: .left)
        machine.pointerMoved(dx: -300, dy: 0) // delta = +300 -> position 300
        XCTAssertEqual(machine.state, .dexActive)
        // Pull back 340 total: 300 - 340 = -40 (still above -60, no return).
        machine.pointerMoved(dx: 40, dy: 0)
        machine.pointerMoved(dx: 300, dy: 0)
        XCTAssertEqual(machine.state, .dexActive)
        machine.pointerMoved(dx: 20, dy: 0) // -60 -> return
        XCTAssertEqual(machine.state, .macActive)
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
        let machine = makeDexActive(edge: .left)
        for (dx, dy) in trace {
            machine.pointerMoved(dx: dx, dy: dy)
        }
        XCTAssertEqual(machine.state, .dexActive,
                       "sustained movement toward Android must never return")
    }

    func testRealLeftEdgeReturnTraceReturnsOnlyAfterCrossingHysteresis() {
        // Left edge: user pushed 300 into DeX, then pulled back toward macOS
        // in the recorded event sequence. Return must fire only when the
        // position crosses -60, not on the first pull-back event.
        let machine = makeDexActive(edge: .left)
        machine.pointerMoved(dx: -300, dy: 0) // into Android (first event, exempt), pos +300
        let pullBack: [(dx: CGFloat, dy: CGFloat)] = [
            (81, -34), (103, -37), (111, -34), (138, -38),
        ]
        var returned = false
        for (dx, dy) in pullBack {
            machine.pointerMoved(dx: dx, dy: dy)
            if machine.state == .macActive { returned = true; break }
        }
        // left edge: delta = -dx. 300 - 81 - 103 = 116 (still inside),
        // -111 -> 5 (still inside), -138 -> -133 (crosses -60, 4th event).
        XCTAssertTrue(returned, "pull-back past the boundary + hysteresis must return")
        XCTAssertEqual(machine.state, .macActive)
    }

    // MARK: - Equivalence with origin/main (left/right)
    // origin/main: left delta=dx returns when accumulator >= 60 (dx>0 is back
    // toward macOS); right delta=-dx returns when accumulator >= 60 (dx<0 is
    // back toward macOS). The virtual-position model with -returnHysteresis is
    // mathematically identical for these edges; the traces below must behave
    // the same under both models.

    func testLeftEdgeEquivalenceWithOriginMain() {
        let machine = makeDexActive(edge: .left)
        // PR: position = -Σdx, return at <= -60  ⟺  Σdx >= 60 (main).
        machine.pointerMoved(dx: -100, dy: 0) // first event: exempt, pos 100
        machine.pointerMoved(dx: -20, dy: 0)  // pos 120
        machine.pointerMoved(dx: -40, dy: 0)  // pos 160
        machine.pointerMoved(dx: 100, dy: 0)  // pos 60; main Σdx=-60 < 60: active
        XCTAssertEqual(machine.state, .dexActive)
        machine.pointerMoved(dx: 100, dy: 0)  // pos -40; main Σdx=40 < 60: active
        XCTAssertEqual(machine.state, .dexActive)
        machine.pointerMoved(dx: 20, dy: 0)   // pos -60; main Σdx=60 -> return
        XCTAssertEqual(machine.state, .macActive)
    }

    func testRightEdgeEquivalenceWithOriginMain() {
        let machine = makeDexActive(edge: .right)
        // PR: position = Σdx, return at <= -60  ⟺  Σdx <= -60 (main).
        machine.pointerMoved(dx: 100, dy: 0)  // first event: exempt, pos 100
        machine.pointerMoved(dx: 20, dy: 0)   // pos 120
        machine.pointerMoved(dx: 40, dy: 0)   // pos 160
        machine.pointerMoved(dx: -100, dy: 0) // pos 60; main -Σdx=60: active
        XCTAssertEqual(machine.state, .dexActive)
        machine.pointerMoved(dx: -100, dy: 0) // pos -40; main -Σdx=40: active
        XCTAssertEqual(machine.state, .dexActive)
        machine.pointerMoved(dx: -20, dy: 0)  // pos -60; main -Σdx=60 -> return
        XCTAssertEqual(machine.state, .macActive)
    }

    // MARK: - Transition reasons (root-cause tracing)

    func testBoundaryCrossedReasonIsReported() {
        let machine = makeDexActive(edge: .left)
        let collector = TransitionCollector()
        machine.onStateChange = { collector.append($0, $1) }
        machine.pointerMoved(dx: -100, dy: 0)
        machine.pointerMoved(dx: 160, dy: 0) // pos -60 -> boundary crossed
        XCTAssertEqual(collector.transitions.map(\.1), [.boundaryCrossed, .boundaryCrossed],
                       "dexActive -> recovering -> macActive, both boundaryCrossed")
    }

    func testConnectionLostReasonIsReported() {
        let machine = makeDexActive(edge: .left)
        let collector = TransitionCollector()
        machine.onStateChange = { collector.append($0, $1) }
        machine.connectionLost()
        XCTAssertEqual(collector.transitions.last?.1, .connectionLost)
        XCTAssertEqual(machine.state, .recovering)
    }

    func testEmergencyReturnReasonIsReported() {
        let machine = makeDexActive(edge: .left)
        let collector = TransitionCollector()
        machine.onStateChange = { collector.append($0, $1) }
        machine.emergencyReturn(reason: .emergencyReturn)
        XCTAssertEqual(collector.transitions.map(\.1), [.emergencyReturn, .emergencyReturn])
        XCTAssertEqual(machine.state, .macActive)
    }

    func testSuppressionReleasedReasonIsReported() {
        let machine = makeDexActive(edge: .left)
        let collector = TransitionCollector()
        machine.onStateChange = { collector.append($0, $1) }
        machine.emergencyReturn(reason: .suppressionReleased)
        XCTAssertEqual(collector.transitions.map(\.1), [.suppressionReleased, .suppressionReleased])
    }

    func testWatchdogTimeoutReasonIsReported() {
        let machine = makeDexActive(edge: .left)
        let collector = TransitionCollector()
        machine.onStateChange = { collector.append($0, $1) }
        machine.emergencyReturn(reason: .watchdogTimeout)
        XCTAssertEqual(collector.transitions.map(\.1), [.watchdogTimeout, .watchdogTimeout])
    }

    func testEdgeEnteredReasonIsReported() {
        let machine = EdgeSwitchStateMachine()
        machine.activate()
        machine.connectionBegan()
        machine.connectionReady()
        let collector = TransitionCollector()
        machine.onStateChange = { collector.append($0, $1) }
        machine.pointerAtEdge(.left)
        XCTAssertEqual(collector.transitions.map(\.1), [.edgeEntered, .edgeEntered],
                       "macActive -> edgeArmed -> dexActive, both edgeEntered")
    }

    func testActivationAndConnectionReasonsAreReported() {
        let machine = EdgeSwitchStateMachine()
        let collector = TransitionCollector()
        machine.onStateChange = { collector.append($0, $1) }
        machine.activate()
        machine.connectionBegan()
        machine.connectionReady()
        XCTAssertEqual(collector.transitions.map(\.1), [.activation, .connectionBegan, .connectionReady])
    }

    // MARK: - Fail-safes

    func testFailSafeEmergencyReturnGoesToMacActive() {
        for edge in [ScreenEdge.left, .right, .top, .bottom] {
            let machine = makeDexActive(edge: edge)
            machine.emergencyReturn()
            XCTAssertEqual(machine.state, .macActive, "\(edge)")
        }
    }

    func testFailSafeConnectionLostWhileDexActiveGoesToRecovering() {
        let machine = makeDexActive(edge: .left)
        machine.connectionLost()
        XCTAssertEqual(machine.state, .recovering)
    }

    func testMovementWhileMacActiveHasNoEffect() {
        let machine = EdgeSwitchStateMachine()
        machine.activate()
        machine.connectionBegan()
        machine.connectionReady()
        XCTAssertEqual(machine.state, .macActive)
        machine.pointerMoved(dx: -1000, dy: 0)
        XCTAssertEqual(machine.state, .macActive)
    }

    func testMovementWhileDisabledHasNoEffect() {
        let machine = EdgeSwitchStateMachine()
        machine.pointerMoved(dx: -1000, dy: 0)
        XCTAssertEqual(machine.state, .disabled)
    }

    func testMovementAfterReturnToMacOSHasNoEffect() {
        let machine = makeDexActive(edge: .right)
        machine.pointerMoved(dx: 300, dy: 0)
        machine.pointerMoved(dx: -360, dy: 0)
        XCTAssertEqual(machine.state, .macActive)
        machine.pointerMoved(dx: -1000, dy: 0)
        XCTAssertEqual(machine.state, .macActive)
    }

    // MARK: - Re-entering resets the virtual position

    func testReenteringEdgeResetsVirtualPosition() {
        // Enter -> return -> re-enter. The stale position from the first session
        // must be reset; a small wobble after re-entering must not return.
        let machine = makeDexActive(edge: .right)
        machine.pointerMoved(dx: 300, dy: 0)
        machine.pointerMoved(dx: -360, dy: 0)
        XCTAssertEqual(machine.state, .macActive)

        machine.pointerAtEdge(.right)
        XCTAssertEqual(machine.state, .dexActive)
        machine.pointerMoved(dx: -30, dy: 0) // first event after re-entry, normalized to 0
        machine.pointerMoved(dx: -61, dy: 0) // second: -61 past hysteresis
        XCTAssertEqual(machine.state, .macActive)
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

        let perReport = makeDexActive(edge: .right)
        for report in raw.reports {
            perReport.pointerMoved(dx: CGFloat(report.dx), dy: CGFloat(report.dy))
        }
        XCTAssertEqual(perReport.state, .dexActive)

        // Pull back 361 in split form: 300 - 361 = -61 -> past hysteresis.
        let pull = HIDReportSplitter.normalizeForHID(dx: -361, dy: 0)
        for report in pull.reports {
            perReport.pointerMoved(dx: CGFloat(report.dx), dy: CGFloat(report.dy))
        }
        XCTAssertEqual(perReport.state, .macActive)
    }

    func testVirtualPositionMatchesDeliveredWhenFedOncePerEvent() {
        // One pointerMoved call with the delivered total behaves identically
        // to per-report feeding (the send(event:) path in main.swift).
        let machine = makeDexActive(edge: .right)
        machine.pointerMoved(dx: 300, dy: 0)
        machine.pointerMoved(dx: -359, dy: 0) // 300 - 359 = -59: not yet
        XCTAssertEqual(machine.state, .dexActive)
        machine.pointerMoved(dx: -2, dy: 0) // -61: past hysteresis
        XCTAssertEqual(machine.state, .macActive)
    }
}
