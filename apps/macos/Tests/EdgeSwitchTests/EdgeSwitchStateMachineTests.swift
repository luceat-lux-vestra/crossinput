import XCTest
@testable import EdgeSwitch

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

    // MARK: - First event regression (the original bug)

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

    func testFirstMovementPastHysteresisReturns() {
        let machine = makeDexActive(edge: .right)
        machine.pointerMoved(dx: -61, dy: 0)
        XCTAssertEqual(machine.state, .macActive, "deliberate immediate return past hysteresis")
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
        machine.pointerMoved(dx: -30, dy: 0) // before crossing back out
        XCTAssertEqual(machine.state, .dexActive)
        machine.pointerMoved(dx: -31, dy: 0) // total -61 past hysteresis
        XCTAssertEqual(machine.state, .macActive)
    }
}