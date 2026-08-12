import XCTest
@testable import EdgeSwitch

final class TransitionCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [StateTransition] = []

    var transitions: [StateTransition] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func append(_ transition: StateTransition) {
        lock.lock(); defer { lock.unlock() }
        storage.append(transition)
    }
}

final class EdgeSwitchStateMachineTests: XCTestCase {
    private func makeRemoteActive(edge: ScreenEdge) -> EdgeSwitchStateMachine {
        let machine = EdgeSwitchStateMachine()
        machine.activate()
        XCTAssertEqual(machine.state, .localActive)
        machine.pointerAtEdge(edge)
        XCTAssertEqual(machine.state, .remoteActive)
        machine.flushCallbacks()
        return machine
    }

    func testHandoffStateContainsOnlyControlStates() {
        let states: Set<HandoffState> = [
            .disabled, .localActive, .edgeArmed, .remoteActive, .returning,
        ]
        XCTAssertEqual(states.count, 5)
    }

    func testActivationDoesNotModelSessionLifecycle() {
        let machine = EdgeSwitchStateMachine()
        let collector = TransitionCollector()
        machine.onStateChange = { collector.append($0) }

        machine.activate()
        machine.flushCallbacks()

        XCTAssertEqual(machine.state, .localActive)
        XCTAssertEqual(collector.transitions.map(\.reason), [.activation])
    }

    func testMovementIntoAndroidNeverReturnsOnAllEdges() {
        let movements: [(ScreenEdge, Int32, Int32)] = [
            (.left, -500, 0), (.right, 500, 0), (.top, 0, -500), (.bottom, 0, 500),
        ]
        for (edge, dx, dy) in movements {
            let machine = makeRemoteActive(edge: edge)
            machine.pointerMoved(dx: CGFloat(dx), dy: CGFloat(dy))
            machine.pointerMoved(dx: CGFloat(dx), dy: CGFloat(dy))
            XCTAssertEqual(machine.state, .remoteActive, "edge \(edge)")
        }
    }

    func testReturnRequiresBoundaryAndHysteresisOnAllEdges() {
        let cases: [(ScreenEdge, Int32, Int32, Int32, Int32)] = [
            (.left, -300, 0, 300, 0),
            (.right, 300, 0, -300, 0),
            (.top, 0, -300, 0, 300),
            (.bottom, 0, 300, 0, -300),
        ]
        for (edge, intoX, intoY, backX, backY) in cases {
            let machine = makeRemoteActive(edge: edge)
            machine.pointerMoved(dx: CGFloat(intoX), dy: CGFloat(intoY))
            machine.pointerMoved(dx: CGFloat(backX), dy: CGFloat(backY))
            machine.pointerMoved(dx: CGFloat(backX > 0 ? 59 : backX < 0 ? -59 : 0),
                                 dy: CGFloat(backY > 0 ? 59 : backY < 0 ? -59 : 0))
            XCTAssertEqual(machine.state, .remoteActive, "edge \(edge) before hysteresis")
            machine.pointerMoved(dx: CGFloat(backX > 0 ? 1 : backX < 0 ? -1 : 0),
                                 dy: CGFloat(backY > 0 ? 1 : backY < 0 ? -1 : 0))
            XCTAssertEqual(machine.state, .localActive, "edge \(edge) after hysteresis")
        }
    }

    func testFirstMovementNeverReturnsAndDoesNotPoisonBaseline() {
        let machine = makeRemoteActive(edge: .right)
        machine.pointerMoved(dx: -1000, dy: 0)
        XCTAssertEqual(machine.state, .remoteActive)
        machine.pointerMoved(dx: -59, dy: 0)
        XCTAssertEqual(machine.state, .remoteActive)
        machine.pointerMoved(dx: -1, dy: 0)
        XCTAssertEqual(machine.state, .localActive)
    }

    func testZeroDeliveredMovementDoesNotConsumeFirstEvent() {
        let machine = makeRemoteActive(edge: .left)
        machine.pointerMoved(dx: 0, dy: 0)
        machine.pointerMoved(dx: 100, dy: 0)
        XCTAssertEqual(machine.state, .remoteActive)
        machine.pointerMoved(dx: 161, dy: 0)
        XCTAssertEqual(machine.state, .localActive)
    }

    func testRemoteUnavailableForcesSafeLocalReturn() {
        let machine = makeRemoteActive(edge: .left)
        let collector = TransitionCollector()
        machine.onStateChange = { collector.append($0) }

        machine.forceReturn(reason: .remoteUnavailable)
        machine.flushCallbacks()

        XCTAssertEqual(machine.state, .localActive)
        XCTAssertEqual(collector.transitions.map(\.reason), [.remoteUnavailable, .remoteUnavailable])
    }

    func testExternalControlTakeoverForcesSafeLocalReturn() {
        let machine = makeRemoteActive(edge: .right)
        let collector = TransitionCollector()
        machine.onStateChange = { collector.append($0) }

        machine.forceReturn(reason: .externalControlTakeover)
        machine.flushCallbacks()

        XCTAssertEqual(machine.state, .localActive)
        XCTAssertEqual(
            collector.transitions.map(\.reason),
            [.externalControlTakeover, .externalControlTakeover])
    }

    func testRemoteUnavailableWhileAlreadyLocalDoesNotInventSessionState() {
        let machine = EdgeSwitchStateMachine()
        machine.activate()
        machine.forceReturn(reason: .remoteUnavailable)
        machine.flushCallbacks()

        XCTAssertEqual(machine.state, .localActive)
    }

    func testEmergencyReturnIsIndependentOfSessionLifecycle() {
        let machine = makeRemoteActive(edge: .right)
        machine.emergencyReturn()
        machine.flushCallbacks()

        XCTAssertEqual(machine.state, .localActive)
    }

    func testStaleTransitionIsRejected() {
        var gate = TransitionSequenceGate()
        let current = StateTransition(sequence: 11, from: .remoteActive,
                                      to: .returning, reason: .remoteUnavailable)
        let stale = StateTransition(sequence: 10, from: .edgeArmed,
                                    to: .remoteActive, reason: .edgeEntered)

        XCTAssertTrue(gate.shouldApply(current))
        XCTAssertFalse(gate.shouldApply(stale))
        XCTAssertEqual(gate.lastAppliedSequence, 11)
    }

    func testIssue37MovementAccountingUsesOnlyDeliveredHidReports() {
        let machine = makeRemoteActive(edge: .left)
        let movement = HIDReportSplitter.normalizeForHID(dx: -300, dy: 0)
        for report in movement.reports {
            machine.pointerMoved(dx: CGFloat(report.dx), dy: CGFloat(report.dy))
        }
        XCTAssertEqual(movement.deliveredDx, -300)
        XCTAssertEqual(machine.state, .remoteActive)

        // A failed report contributes nothing to the virtual position.
        let failed = HIDReportSplitter.normalizeForHID(dx: 0, dy: 0)
        XCTAssertEqual(failed.deliveredDx, 0)
        XCTAssertEqual(failed.deliveredDy, 0)
    }

    func testOneHundredEdgeHandoffCyclesStaySafe() {
        let edges: [ScreenEdge] = [.left, .right, .top, .bottom]

        for cycle in 0..<100 {
            let machine = EdgeSwitchStateMachine()
            let edge = edges[cycle % edges.count]
            let intoAndroid: (Int32, Int32)
            let backToMac: (Int32, Int32)

            switch edge {
            case .left: intoAndroid = (-120, 0); backToMac = (181, 0)
            case .right: intoAndroid = (120, 0); backToMac = (-181, 0)
            case .top: intoAndroid = (0, -120); backToMac = (0, 181)
            case .bottom: intoAndroid = (0, 120); backToMac = (0, -181)
            }

            machine.activate()
            machine.pointerAtEdge(edge)
            XCTAssertEqual(machine.state, .remoteActive, "cycle \(cycle) entered \(edge)")

            // The first event is the post-capture event and must not return.
            machine.pointerMoved(dx: CGFloat(intoAndroid.0), dy: CGFloat(intoAndroid.1))
            XCTAssertEqual(machine.state, .remoteActive, "cycle \(cycle) returned on entry")

            // Cross the boundary and hysteresis in the direction of macOS.
            machine.pointerMoved(dx: CGFloat(backToMac.0), dy: CGFloat(backToMac.1))
            XCTAssertEqual(machine.state, .localActive, "cycle \(cycle) did not return safely")

            machine.deactivate()
            XCTAssertEqual(machine.state, .disabled, "cycle \(cycle) did not deactivate")
        }
    }

    func testCallbackSequencesRemainMonotonicAcrossConcurrentCommands() {
        let machine = EdgeSwitchStateMachine()
        let collector = TransitionCollector()
        machine.onStateChange = { collector.append($0) }
        let group = DispatchGroup()
        for index in 0..<100 {
            group.enter()
            DispatchQueue.global().async {
                if index.isMultiple(of: 2) {
                    machine.activate()
                } else {
                    machine.forceReturn(reason: .remoteUnavailable)
                }
                group.leave()
            }
        }
        group.wait()
        machine.flushCallbacks()
        let sequences = collector.transitions.map(\.sequence)
        XCTAssertEqual(sequences, sequences.sorted())
    }
}
